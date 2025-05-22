export default async function (subgraph: string, block: number) {
  let last: string | undefined = "";
  const set = new Set<string>();
  do {
    const { accounts } = (
      await (
        await fetch(subgraph, {
          method: "POST",
          headers: { "Content-Type": "application/json", origin: "https://app.exact.ly" },
          body: JSON.stringify({
            query: `{
              accounts(
                first: 1000
                block: { number: ${block} }
                where: { address_gt: "${last}" }
                orderBy: address
                orderDirection: asc
              ) { address }
            }`,
          }),
        })
      ).json()
    ).data as { accounts: { address: string }[] };
    accounts.forEach(({ address }: { address: string }) => set.add(address));
    last = accounts.length ? [...set][set.size - 1] : undefined;
  } while (last);
  return [...set];
}
