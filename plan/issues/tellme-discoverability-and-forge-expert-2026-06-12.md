# Forge Discoverability via "tellme" and Forge-Expert Inference Model

**Context:**
The forge environment needs intuitive discoverability for operators and developers. We will introduce a `tellme` command-line utility globally available in the forge.

**Requirements:**
1. **`tellme about [topic]`**: Returns static cheatsheet summaries (e.g., "tellme about the forge", "tellme about java", "tellme about linux", "tellme about podman").
   - This must include the **"forge dependency list"** tracking all foreign DNF repositories, providing users transparency into the source of all binaries.
2. **`tellme howto [query]`**: Uses a local inference engine to answer complex or dynamic questions (e.g., "tellme howto compile the main module").
3. **Forge-Expert Model**: 
   - A specialized <1B parameter model focused exclusively on answering questions about the forge environment and the specific checked-out project.
   - Extremely fast execution with NO tool usage.
   - Trained at launch time with knowledge of the forge (cheatsheets about the forge, git mirror, vault, chrome safe/unsafe browsers, podman, WSL2, and OSX Containers) and the current project.
   - Automated re-training triggered by commits to the repository, so the next `tellme howto` invocation has up-to-date context immediately.
4. **Skill Mapping into Forge**:
   - Skills living in `./skills/` must be mapped into the forge.
   - Ensure the image build process (`images/default/Containerfile`) copies designated skills so agents running inside the forge have immediate access to them.
