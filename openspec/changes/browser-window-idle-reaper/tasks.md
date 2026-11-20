## 1. Dev-browser lifecycle discipline

- [x] 1.1 Idle reaper: a configurable limit (default 15 min); stops the window, its forwarder and its network; answers browser.closed:idle; tool calls count as activity; dev windows record user input
- [x] 1.2 Affordance: the browser.open result and descriptions, browser.close description, and the forge instructions say to close the window when done
- [ ] 1.3 A headless window with nobody viewing it stops rendering continuously (throttle or stop); record the measured CPU
