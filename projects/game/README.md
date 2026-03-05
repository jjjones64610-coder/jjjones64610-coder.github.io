#Project 02: Escape from the Sunken Aquarium
**A Beginner JavaScript Text Adventure**

You are a diver trapped in a decaying underwater research facility. The glass is cracking under the pressure, and you have exactly 5 stages to find the surface hatch before the facility collapses.

---

##Game World Map
This flowchart shows the paths you can take to escape:

```mermaid
graph TD
    %% Starting Areas
    Oxygen[Oxygen Storage] --> Cafe[The Coral Cafe]
    Cafe --> Central[The Central Hub]
    
    Archive[The Data Archive] --> Central
    
    Sub((The Escape Sub)) --> Central
    
    %% Middle Path
    Central --> Tunnel[The Shark Tunnel]
    Tunnel --> Shed[The Control Shed]
    
    %% Final Branches
    Shed --> RM511[Hatch 511 - ESCAPE]
    Shed --> Pump[The Pump Room - TRAPPED]
    
    %% DARK BLUE STYLES
    style Oxygen fill:#001f3f,stroke:#0074D9,color:#fff
    style Cafe fill:#001f3f,stroke:#0074D9,color:#fff
    style Archive fill:#001f3f,stroke:#0074D9,color:#fff
    style Sub fill:#001f3f,stroke:#0074D9,color:#fff
    style Central fill:#001f3f,stroke:#0074D9,color:#fff
    style Tunnel fill:#001f3f,stroke:#0074D9,color:#fff
    style Shed fill:#001f3f,stroke:#0074D9,color:#fff
    
    %% Special Colors for Endings
    style RM511 fill:#004080,stroke:#39CCCC,color:#fff
    style Pump fill:#1a0000,stroke:#FF4136,color:#fff
