export async function isShell(url: string): Promise<boolean> {
  const response = await fetch(url).catch(() => null);
  if (!response?.ok) return false;
  const html = await response.text().catch(() => "");
  return new DOMParser().parseFromString(html, "text/html").body.dataset.version !== undefined;
}
