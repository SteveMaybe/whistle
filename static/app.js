let socket = new WebSocket("ws://localhost:4000/ws/1")
let target = document.querySelector("#target");

function renderVirtualDom(vdom) {
  let node = null;

  if(vdom[0] == "text") {
    node = document.createTextNode(vdom[2])
  } else {
    node = document.createElement(vdom[0]);
    for (var key in vdom[1]) {
      const attributeValue = vdom[1][key];
      if(key == "on") {
        attributeValue.forEach(function(eventName) {
          node.addEventListener(eventName, function(e) {
            socket.send(JSON.stringify({
              handler: vdom[1].key + "." + eventName,
              arguments: [e.target.value]
            }));
          });
        });
      } else {
        node.setAttribute(key, attributeValue);
      }
    }

    vdom[2].forEach(function(child) {
      let childNode = renderVirtualDom(child);
      node.appendChild(childNode);
    });
  }

  return node;
}

function findNodeByPath(parent, path) {
  return path.reduce(function(node, index) {
    return node.childNodes[index];
  }, parent);
}

socket.addEventListener("open", (event) => {
})

socket.addEventListener("message", (event) => {
  let patches = JSON.parse(event.data);

  patches.forEach(function(patch) {
    switch(patch[0]) {
      case "replace_node":
        {
          const node = renderVirtualDom(patch[2]);
          findNodeByPath(target, patch[1]).replaceWith(node);
        }
        break;

      case "add_node":
        {
          const parent = findNodeByPath(target, patch[1]);
          const node = renderVirtualDom(patch[2]);
          parent.appendChild(node);
        }
        break;

      case "set_attribute":
        {
          let replaceTarget = findNodeByPath(target, patch[1]);
          if(patch[2][0] == "value") {
            replaceTarget.value = patch[2][1];
          } else{
            replaceTarget.setAttribute(patch[2][0], patch[2][1]);
          }
        }
        break;

      case "replace_text":
        {
          findNodeByPath(target, patch[1]).replaceWith(patch[2]);
        }
        break;
    }
  });
})

