export const INTERVAL = 86_400 * 7 * 4;

export default (n = 3, interval = INTERVAL) => {
  const now = Math.floor(Date.now() / 1_000);
  return [...new Array(n)].map((_, i) => now - (now % interval) + interval * (i + 1));
};
