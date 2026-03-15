/** LLMs sometimes return [{ caption: "..." }] instead of string[]. */
export function normalizeImageDescriptor(d: unknown): string {
  if (d == null) return "";
  if (typeof d === "string") return d;
  if (typeof d === "object" && d !== null) {
    const o = d as Record<string, unknown>;
    if (typeof o.caption === "string") return o.caption;
    if (typeof o.text === "string") return o.text;
    if (typeof o.description === "string") return o.description;
  }
  try {
    return JSON.stringify(d);
  } catch {
    return String(d);
  }
}

export function normalizeImageDescriptors(
  arr: unknown[] | undefined
): string[] {
  if (!Array.isArray(arr)) return [];
  return arr.map(normalizeImageDescriptor).filter(Boolean);
}
