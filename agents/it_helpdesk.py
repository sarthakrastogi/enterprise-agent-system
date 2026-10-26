from eap import AgentSpec, prompt_from_file

agent = AgentSpec(
    name="it_helpdesk",
    display_name="IT Helpdesk",
    description="Answers IT and policy questions from the company knowledge base and files or tracks support tickets.",
    system_prompt=prompt_from_file("prompts/it_helpdesk.md", relative_to=__file__),
    tools=[
        "knowledge___search_policies",
        "knowledge___get_policy",
        "tickets___create_ticket",
        "tickets___get_ticket",
        "tickets___list_my_tickets",
        "tickets___close_ticket",       # Cedar policy only lets platform-admins call this
    ],
    sub_agents=["data_analyst"],
    memory=True,
    allowed_groups=["employees"],
    version="0.1.0",
)
