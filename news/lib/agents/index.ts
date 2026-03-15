import { createClaudeProvider } from "@/lib/agents/claude";
import { mockProvider } from "@/lib/agents/mock";
import { createOpenAIProvider } from "@/lib/agents/openai";
import type { LLMProvider } from "@/lib/agents/types";

/** Claude (Anthropic) preferred; else OpenAI; else mock. */
export function getLLMProvider(): LLMProvider {
  if (process.env.CLAUDE_API_KEY?.trim()) return createClaudeProvider();
  if (process.env.OPENAI_API_KEY?.trim()) return createOpenAIProvider();
  return mockProvider;
}

export { mockProvider } from "@/lib/agents/mock";
export type { LLMProvider } from "@/lib/agents/types";
