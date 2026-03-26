let canvas = document.getElementById("canvas1");

let ctx = canvas.getContext("2d");

//fill in code for canvas1 here

canvas = document.getElementById("canvas2");
ctx = canvas.getContext("2d");

for (let y = 0; y < 800; y += 20) {
  for (let x = 200; x < y + 200; x += 20) {
    ctx.fillRect(x, y, 15, 4);
  }
}

canvas = document.getElementById("canvas3");
ctx = canvas.getContext("2d");

//fill in code for canvas3 here

canvas = document.getElementById("canvas4");
ctx = canvas.getContext("2d");

//fill in code for canvas4 here
