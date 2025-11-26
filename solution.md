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
