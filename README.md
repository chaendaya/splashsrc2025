SPLASH 2025 Student Research Competition


# On A Multitier Actor Programming Language

HYEONJIN LEE



# Implementation
Built on pure functional Haskell, MAPL integrates RPC calculus into Agha’s Actor model
and supporting real distributed execution on Cloud Haskell.

<img width="782" height="292" alt="image" src="https://github.com/user-attachments/assets/94782368-bb28-435a-aee8-f4d68a25344c" />

- multi-tier actor calculus (operational semantics) (2025.09 update)
  [mapl semantics.pdf](https://github.com/user-attachments/files/22930067/mapl.semantics.pdf)




## Build and Run Instructions

```
> cd splashsrc2025\multitier_actor

> stack build multitier-actor:exe:actors-exe

> stack run actors-exe main <ip>:<port> .\app\actors\examples\splashsrc2025\<fileName>
```
e.g. 
`stack run actors-exe main 127.0.0.1:8080 .\app\actors\examples\splashsrc2025\bookseller1.actor`
