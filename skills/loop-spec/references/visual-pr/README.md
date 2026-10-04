# visual-pr: the PR description format

For a contributor: where the PR description format comes from. The lead reaches
[pr_description_template.md](pr_description_template.md) directly from the hub skill,
for a repository with no PR template of its own.

The template is copied unchanged from HumanLayer's
[visual-pr plugin](https://github.com/humanlayer/skills/tree/main/plugins/visual-pr)
at commit `ca7c8088db69`, under the MIT license in [LICENSE](LICENSE). Only the
template is used: loop-spec's `deliver` pushes and opens the PR, so the plugin's own
workflow (which pushes and saves under `.humanlayer/`) is not.
