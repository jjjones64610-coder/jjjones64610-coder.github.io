// This variable keeps track of which room you are in.
// We start at "start".
let currentRoom = "start";
// This function runs every time you click a button.
// 'choice' will be 1 if you click the left button, and 2 if you click the right.
if (currentRoom === "start") {
        if (choice === 1) {
		currentRoom = "cafe";
print("You leave Oxygen Storage and enter the Coral Cafe. It smells like salt. Go to the Central Hub?", "Go to Central Hub", "Stay Here");
} else if (choice === 2) {
            currentRoom = "archive";
            updateUI("You are in the Data Archive. It is dark and quiet. Swim toward the Central Hub?", "Swim to Central Hub", "Stay Here");
        }
    } 
    else if (currentRoom === "cafe" || currentRoom === "archive") {
        if (choice === 1) {
            currentRoom = "central";
            print("You reached the Central Hub! A giant shark is circling above. Enter the Shark Tunnel?", "Enter Shark Tunnel", "Hide");
        } else {
            gameOver("You waited too long and your air tank ran out. Game Over!");
        }

