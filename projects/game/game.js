// This variable keeps track of which room you are in.
// We start at "start".
let currentRoom = "start";
// This function runs every time you click a button.
// 'choice' will be 1 if you click the left button, and 2 if you click the right.
if (currentRoom == "start") {
        if (choice == 1) {
		currentRoom = "cafe";
print("You leave Oxygen Storage and enter the Coral Cafe. It smells like salt. Go to the Central Hub?", "Go to Central Hub", "Stay Here");
} else if (choice == 2) {
            currentRoom = "archive";
            updateUI("You are in the Data Archive. It is dark and quiet. Swim toward the Central Hub?", "Swim to Central Hub", "Stay Here");
        }
    } 
    else if (currentRoom == "cafe" || currentRoom == "archive") {
        if (choice == 1) {
            currentRoom = "central";
            print("You reached the Central Hub! A giant shark is circling above. Enter the Shark Tunnel?", "Enter Shark Tunnel", "Hide");
        } else {
            gameOver("You waited too long and your air tank ran out. Game Over!");
        }
    }
else if (currentRoom == "central") {
        if (choice == 1) {
            currentRoom = "tunnel";
		print("You are in the glass Shark Tunnel. It is cracking! Run to the Control Shed?", "Run to Shed", "Go Back");
        } else {
            gameOver("You tried to hide, but the room flooded. Game Over!");
        }
    }
else if (currentRoom == "tunnel") {
        if (choice == 1) {
            currentRoom = "shed";
            print("You made it to the Control Shed! There are two doors. Which one do you open?", "Hatch 511", "Pump Room");
        } else {
            gameOver("The glass broke before you could run back! Game Over!");
        }
    }
else if (currentRoom == "shed") {
        if (choice == 1) {
            winGame("You climbed through Hatch 511 and reached the surface! YOU ESCAPED!");
        } else {
		gameOver("The Pump Room was a trap and it flooded instantly! Game Over!");
		}
    }
}
// changes the text
function updateUI(storyText, btn1Text, btn2Text) {
    document.getElementById("story-text").innerText = storyText;
    document.getElementById("btn1").innerText = btn1Text;
    document.getElementById("btn2").innerText = btn2Text;
}

// restart buttion
function gameOver(message) {
    document.getElementById("story-text").innerText = message;
    document.getElementById("button-container").innerHTML = '<button onclick="location.reload()">Try Again</button>';
}

// winning
function winGame(message) {
    document.getElementById("story-text").innerText = message;
    document.getElementById("button-container").innerHTML = '<button onclick="location.reload()">Play Again!</button>';

