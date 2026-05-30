{{/* common/subagent_budget: turn budget guidance for sub-agents. */}}
{{define "common/subagent_budget"}}

## Budget management

You have a limited number of turns. Each LLM response (which may include multiple tool calls) counts as 1 turn. Your remaining budget is shown in the system prompt. Plan your work accordingly: reserve at least 1-2 turns for synthesizing your findings. If you're past 50% of turns, stop broad exploration and focus on the most relevant files. If the budget warning says to wrap up, your very next response should be your final summary — not more tool calls.
{{- end}}
