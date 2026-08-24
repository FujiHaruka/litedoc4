/**
 * One name at a time, reused for the life of the page. Front coding means the
 * previous name's shared prefix is already in place, so a step writes only the
 * suffix — which is why `room` grows these by copying rather than replacing.
 *
 * Exported as `let`: both readers have to see the array `room` grew to, and ES
 * module bindings are live. A getter would be a call in the hottest loop.
 */

export let scratch = new Uint8Array(512);
export let folded = new Uint8Array(512);

/** Make room for a name of `need` bytes, keeping what is already there. */
export function room(need: number): void {
  if (need <= scratch.length) return;
  let size = scratch.length;
  while (size < need) size *= 2;
  const grownScratch = new Uint8Array(size);
  grownScratch.set(scratch);
  const grownFolded = new Uint8Array(size);
  grownFolded.set(folded);
  scratch = grownScratch;
  folded = grownFolded;
}
