## 1. Withdraw the shipped summarizers (2114-sdj6)

- [x] 1.1 Prove nothing in crates/ or images/ embeds, copies or calls a summarizer (evidence in proposal.md)
- [x] 1.2 Delete the six scripts/summarize-*.sh and scripts/test-summarize-pubspec.sh
- [x] 1.3 Retire litmus:project-summarizers-shape: delete the test, drop its binding and the portability floor rows
- [x] 1.4 Delta specs: REMOVE the three shipped-summarizer requirements; MODIFY the bootstrap-readme scenario
- [x] 1.5 Cheatsheet readme-discipline: describe /opt/summarizers as a drop-in directory nothing populates today
- [ ] 1.6 Archive this change after it lands on linux-next
