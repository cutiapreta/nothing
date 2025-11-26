# First Question: 
**Problem Statement**

Write a C program that implements the First-Come, First-Served (FCFS) CPU Scheduling Algorithm for 3 processess, take their burst time and calculate their average wait time.


**Instructions**

- Write a comment to make your code readable.

- Use descriptive variables in your (Name of the variables should show their purposes).

- Ensure your code compiles without any errors/warnings/deprecations 

- Avoid too many & unnecessary usages of white spaces (newline, spaces, tabs, …)

- Always test the code thoroughly, before saving/submitting exercises/projects.


**Example**

If burst time = 3,5,and 7

Average wait time = 3.67 


**solution:**

```C
#include <stdio.h>

int main() {
    int burstTime[3];
    int waitingTime[3];
    int totalWaitingTime = 0;

    // Read 3 burst times
    for (int i = 0; i < 3; i++) {
        scanf("%d", &burstTime[i]);
    }

    // First process waiting time = 0
    waitingTime[0] = 0;

    // Calculate waiting times
    for (int i = 1; i < 3; i++) {
        waitingTime[i] = waitingTime[i - 1] + burstTime[i - 1];
    }

    // Sum waiting times
    for (int i = 0; i < 3; i++) {
        totalWaitingTime += waitingTime[i];
    }

    // Calculate and print average waiting time ONLY
    float averageWaitingTime = totalWaitingTime / 3.0f;
    printf("%.2f", averageWaitingTime);

    return 0;
}
```

**input**: 
```
3 5 7
```

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# second question:

**Problem Statement**

Write a C program that implements the First-Come, First-Served (FCFS) CPU Scheduling Algorithm for 4 processess and calculates average turnaround time.


**Instructions**

- Write a comment to make your code readable.

- Use descriptive variables in your (Name of the variables should show their purposes).

- Ensure your code compiles without any errors/warnings/deprecations 

- Avoid too many & unnecessary usages of white spaces (newline, spaces, tabs, …)

- Always test the code thoroughly, before saving/submitting exercises/projects.


**Example**

If burst time is : 12 1 14 5

average turnaround time = 21.00


**solution:**

```c
#include <stdio.h>

int main() {
    int burstTime[4];
    int turnaroundTime[4];
    int totalTurnaroundTime = 0;

    // Read 4 burst times (no prompt text allowed)
    for (int i = 0; i < 4; i++) {
        scanf("%d", &burstTime[i]);
    }

    // First process turnaround time equals its burst time
    turnaroundTime[0] = burstTime[0];

    // Calculate turnaround times for remaining processes
    for (int i = 1; i < 4; i++) {
        turnaroundTime[i] = turnaroundTime[i - 1] + burstTime[i];
    }

    // Calculate total turnaround time
    for (int i = 0; i < 4; i++) {
        totalTurnaroundTime += turnaroundTime[i];
    }

    // Compute average turnaround time
    float averageTurnaroundTime = totalTurnaroundTime / 4.0f;

    // Output only the required numeric value
    printf("%.2f", averageTurnaroundTime);

    return 0;
}
```

**input:**
```
12 1 14 5
```
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# third question:

**Problem Statement**

Write a C program to calculate the number of page faults using the FIFO (First-In-First-Out) page replacement algorithm for the reference string: 5 0 1 3 2 4 1 0 5

- Frame size = 3


**Instructions**

- Write a comment to make your code readable.

- Use descriptive variables in your (Name of the variables should show their purposes).

- Ensure your code compiles without any errors/warnings/deprecations 

- Avoid too many & unnecessary usages of white spaces (newline, spaces, tabs, …)

- Always test the code thoroughly, before saving/submitting exercises/projects.


**Example**

Number of page faults using the FIFO for the reference string = 9

**solution:**

```c
#include <stdio.h>

int main() {
    int referenceString[] = {5,0,1,3,2,4,1,0,5};
    int referenceCount = 9;

    int frameSize = 3;
    int frames[3];
    int nextFrameIndex = 0;
    int pageFaults = 0;

    // Initialize frames with -1 indicating empty
    for (int i = 0; i < frameSize; i++) {
        frames[i] = -1;
    }

    // FIFO Page Replacement Logic
    for (int i = 0; i < referenceCount; i++) {
        int currentPage = referenceString[i];
        int pageFound = 0;

        // Check if page already exists in frames
        for (int j = 0; j < frameSize; j++) {
            if (frames[j] == currentPage) {
                pageFound = 1;
                break;
            }
        }

        // If page not found → page fault
        if (!pageFound) {
            frames[nextFrameIndex] = currentPage; // Replace using FIFO
            nextFrameIndex = (nextFrameIndex + 1) % frameSize;
            pageFaults++;
        }
    }

    // Output ONLY page fault count
    printf("%d", pageFaults);

    return 0;
}
```

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Fourth question:

**Problem Statement**

Write a C program to implement the LRU (Least Recently Used) Page Replacement Algorithm for the same reference string: 5 0 1 3 2 4 1 0 5, where  Frame capacity = 3


**Instructions**

- Write a comment to make your code readable.

- Use descriptive variables in your (Name of the variables should show their purposes).

- Ensure your code compiles without any errors/warnings/deprecations 

- Avoid too many & unnecessary usages of white spaces (newline, spaces, tabs, …)

- Always test the code thoroughly, before saving/submitting exercises/projects.


**Example**

Total Page Faults = 8

**solution:**

```c
#include <stdio.h>

int main() {
    int referenceString[] = {5,0,1,3,2,4,1,0,5};
    int referenceCount = 9;

    int frameSize = 3;
    int frames[3];
    int lastUsedIndex[3];  // Tracks how recently each frame was used
    int pageFaults = 0;
    int timer = 0;

    // Initialize frames as empty
    for (int i = 0; i < frameSize; i++) {
        frames[i] = -1;
        lastUsedIndex[i] = -1;
    }

    // LRU Page Replacement Logic
    for (int i = 0; i < referenceCount; i++) {
        int currentPage = referenceString[i];
        int pageFound = 0;

        // Check if page already present
        for (int j = 0; j < frameSize; j++) {
            if (frames[j] == currentPage) {
                pageFound = 1;
                lastUsedIndex[j] = timer++;  // update recent usage
                break;
            }
        }

        // If not found → Page Fault
        if (!pageFound) {
            int lruIndex = 0;

            // Find Least Recently Used frame
            for (int j = 1; j < frameSize; j++) {
                if (lastUsedIndex[j] < lastUsedIndex[lruIndex]) {
                    lruIndex = j;
                }
            }

            // Replace LRU page
            frames[lruIndex] = currentPage;
            lastUsedIndex[lruIndex] = timer++;
            pageFaults++;
        }
    }

    // Output only the result
    printf("%d", pageFaults);

    return 0;
}
```
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# fifth question:


**Problem Statement**

Write a C program to implement Round Robin scheduling for 5 processes. Where burst time for process P1 to P5 is - 5 15 4 3 9 and Time Quantum = 4. Calculate their Average Waiting Time and Average Turnaround Time.


**Instructions**

- Write a comment to make your code readable.

- Use descriptive variables in your (Name of the variables should show their purposes).

- Ensure your code compiles without any errors/warnings/deprecations 

- Avoid too many & unnecessary usages of white spaces (newline, spaces, tabs, …)

- Always test the code thoroughly, before saving/submitting exercises/projects.


**Example**

- Average Waiting Time: 15.80
- Average Turnaround Time: 23.00

```c
#include <stdio.h>

int main() {
    int burstTime[5] = {5, 15, 4, 3, 9};
    int remainingTime[5];
    int completionTime[5];
    int waitingTime[5];
    int turnaroundTime[5];

    int timeQuantum = 4;
    int totalTime = 0;
    int processes = 5;

    for (int i = 0; i < processes; i++) {
        remainingTime[i] = burstTime[i];
    }

    int done;
    do {
        done = 1;
        for (int i = 0; i < processes; i++) {
            if (remainingTime[i] > 0) {
                done = 0;

                if (remainingTime[i] <= timeQuantum) {
                    totalTime += remainingTime[i];
                    remainingTime[i] = 0;
                    completionTime[i] = totalTime;
                } else {
                    remainingTime[i] -= timeQuantum;
                    totalTime += timeQuantum;
                }
            }
        }
    } while (!done);

    float sumWT = 0, sumTAT = 0;

    for (int i = 0; i < processes; i++) {
        turnaroundTime[i] = completionTime[i];
        waitingTime[i] = turnaroundTime[i] - burstTime[i];

        sumWT += waitingTime[i];
        sumTAT += turnaroundTime[i];
    }

    printf("%.2f %.2f", sumWT / processes, sumTAT / processes);

    return 0;
}
```
