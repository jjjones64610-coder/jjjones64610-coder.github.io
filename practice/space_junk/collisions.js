function clickHandler(e){
  const mouseX = e.offsetX, mouseY = e.offsetY;
  for(const j of junk) {
    junk_min_x = j.x - 12*j.size;
    junk_max_x = j.x + 12*j.size;
    junk_min_y = j.y - 12*j.size;
    junk_max_y = j.y + 12*j.size;

    //TODO: write some code here that checks whether
    //(mouseX, mouseY) is inside j
if(mouseX < Junk_max_x
&& mouseX > junk_min_x
&& mouseY < junk_max_y
&& mouseY > junk_min_y){
j.alive=false;
  }
}

canvas.addEventListener('click', clickHandler);

function checkCollisions(){
    //todo - loop through all junk/ship pairs
    //check to see whether they're colliding.
    //If so, set both of their alive to false
    for(const j of junk) {
        for(const s of ships){
            if(j.alive && s.alive){
                junk_min_x = j.x - 12*j.size;
                junk_max_x = j.x + 12*j.size;
                junk_min_y = j.y - 12*j.size;
                junk_max_y = j.y + 12*j.size;

                ship_min_x = s.x - 15*s.size;
                ship_max_x = s.x + 15*s.size;
                ship_min_y = s.y - 15*s.size;
                ship_max_y = s.y + 15*s.size;
if(
ship_max_x > junk_min_X
&& ship_min_X < junk_max_X
&& ship_min_Y < junk_max_Y
&& ship_max_Y > junk_min_Y
){

j.alive = false;
s.alive = false;
            }
        }
    }
}
