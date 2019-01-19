defmodule Whistle.Html.Parser do
  import NimbleParsec

  require Whistle.Html
  alias Whistle.Html

  defmodule ParseError do
    defexception string: "", line: 0, col: 0, message: "error parsing HTML"

    def message(e) do
      """

      Failed to parse HTML: #{e.message}

      Check your syntax near line #{e.line} and col #{e.col}:

      #{e.string}
      """
    end
  end


  defp string_to_quoted(expr) do
    {:ok, quoted} = Code.string_to_quoted(expr)
    {:unquote, [], [quoted]}
  end

  defp html_text({:unquote, [], expr}) do
    {:unquote, [], [{:to_string, [], expr}]}
  end

  defp html_text(string) do
    string
  end

  expr =
    ignore(string("\#\{"))
    |> utf8_string([not: ?}], min: 1)
    |> ignore(string("}"))
    |> map(:string_to_quoted)

  tag_name = ascii_string([?a..?z, ?A..?Z], min: 1)
  text = choice([expr, utf8_string([not: ?<], min: 1)]) |> map(:html_text)
  whitespace = ascii_char([?\s, ?\n]) |> repeat() |> ignore()

  closing_tag =
    ignore(string("</"))
    |> concat(tag_name)
    |> ignore(string(">"))
    |> unwrap_and_tag(:closing_tag)

  attribute_value =
    ignore(string("\""))
    |> utf8_string([not: ?"], min: 1)
    |> ignore(string("\""))

  attribute =
    utf8_string([?a..?z, ?-], min: 1)
    |> ignore(string("="))
    |> choice([expr, attribute_value])
    |> wrap()

  opening_tag =
    ignore(string("<"))
    |> concat(tag_name)
    |> unwrap_and_tag(:opening_tag)
    |> repeat(whitespace |> concat(attribute) |> unwrap_and_tag(:attributes))
    |> concat(whitespace)

  comment =
    ignore(string("<!--"))
    |> repeat(lookahead_not(string("-->")) |> utf8_char([]))
    |> ignore(string("-->"))
    |> ignore()

  children =
    parsec(:do_parse)
    |> tag(:child)

  tag =
    opening_tag
    |> choice([
      ignore(string("/>")),
      ignore(string(">"))
      |> concat(whitespace)
      |> concat(children)
      |> concat(closing_tag)
      |> concat(whitespace)
    ])
    |> post_traverse(:validate_node)

  defparsecp(:do_parse, whitespace |> repeat(choice([tag, text, comment])))

  defparsec(:parse, parsec(:do_parse) |> eos)

  defp validate_node(_rest, args, context, _line, _offset) do
    opening_tag = Keyword.get(args, :opening_tag)
    closing_tag = Keyword.get(args, :closing_tag)

    cond do
      opening_tag == closing_tag or closing_tag == nil ->
        tag = opening_tag

        attributes =
          Keyword.get_values(args, :attributes)
          |> Enum.reverse()
          |> Enum.map(fn
            ["on-" <> event, value] ->
              {:on, [{String.to_atom(event), value}]}

            [key, value] ->
              underscore_key =
                String.replace(key, "-", "_")

              {String.to_atom(underscore_key), value}
          end)

        children =
          args
          |> Keyword.get_values(:child)
          |> Enum.reverse()

        acc = Html.node(tag, attributes, List.flatten(children))

        {[acc], context}

      true ->
        {:error, "Closing tag #{closing_tag} did not match opening tag #{opening_tag}"}
    end
  end

  defmacro sigil_H({:<<>>, _, iolist}, _) do
    case HtmlParser.parse(to_string(iolist)) do
      {:ok, nodes, _, _, _, _} ->
        Macro.escape(List.first(nodes), unquote: true)

      a = {:error, reason, rest, _, {line, col}, _} ->
        raise %ParseError{string: String.slice(rest, 0..40), line: line, col: col, message: reason}
    end
  end
end
