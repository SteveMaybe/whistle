defmodule HtmlTest do
  use ExUnit.Case
  import Whistle.Html.Parser

  require Whistle.Html
  alias Whistle.Html

  doctest Whistle.Html

  test "html parser" do
    number = 5

    assert ~H"" == nil
    assert ~H"some text" == Html.text("some text")
    assert ~H"{{ to_string(number) }}" == Html.text(number)
    assert ~H|<div>{{ to_string(number) }}</div>| == Html.div([], ["#{number}"])
    assert ~H({{ "text" }}) == Html.text("text")
    assert ~H({{ "}\}" }}) == Html.text("}}")
    assert ~H(<!-- test -->) == nil
    assert ~H"<div></div>" == Html.div()
    assert ~H(<input key="value" />) == Html.input(key: "value")
    assert ~H(<div key="value"></div>) == Html.div(key: "value")
    assert ~H(<div key={{ number }}></div>) == Html.div(key: number)
    assert ~H(<div on-click={{ :test }}></div>) == Html.div(on: [click: :test])

    assert ~H(<div key={{ number }}><span></span></div>) ==
             Html.div([key: number], [
               Html.span()
             ])
  end

  test "html macros flatten and assign keys to children" do
    todos = ["first", "second"]

    expected =
      {"div", {[], [{0, {"p", {[], [{0, "first"}]}}}, {1, {"p", {[], [{0, "second"}]}}}]}}

    assert expected == ~H"""
           <div>{{ todos |> Enum.map(fn title -> Html.p([], title) end) }}</div>
           """

    assert expected == Html.div([], todos |> Enum.map(fn title -> Html.p([], title) end))
  end
end
