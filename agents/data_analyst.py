from eap import AgentSpec, prompt_from_file

agent = AgentSpec(
    name="data_analyst",
    display_name="Data Analyst",
    description="Does calculations and analysis on data you give it by running Python in a secure sandbox; returns the result and how it was computed.",
    system_prompt=prompt_from_file("prompts/data_analyst.md", relative_to=__file__),
    builtin_tools=["code_interpreter"],
    temperature=0.0,
    allowed_groups=["employees"],
    version="0.1.0",
)
