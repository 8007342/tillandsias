## 1. Gate reads committed records (2080-qqsm)

- [ ] 1.1 Fixture: a scratch project repo with one valid committed record and no state-dir copy; assert the fetch is admitted (red today)
- [ ] 1.2 `licence_consent` reads records from the project mirror at the requested branch
- [ ] 1.3 Remove the state-dir copy path from `admits_restricted` and from accept-licence step 4
- [ ] 1.4 Run the fixture on Linux, in the macOS guest and in the Windows distro

## 2. History-anchored verification (2081-qndc)

- [ ] 2.1 Fixture: delete host allowed_signers, enrol a new key, assert an old record still verifies (red today)
- [ ] 2.2 Fixture: a record signed by a key never committed is refused; a signer added in the same commit as its record is refused; a record modified after it was added is refused
- [ ] 2.3 Verifier takes signer bytes read at the adding commit instead of a host path
- [ ] 2.4 accept-licence commits the signer line before the first record that uses it

## 3. Migration (2080-ryc8)

- [ ] 3.1 Fixture: two state-dir records for two projects become two commits; an orphan is reported
- [ ] 3.2 Remove the state-dir directory only after every record is found in git
