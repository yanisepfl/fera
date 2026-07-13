import type { Metadata } from "next";
import { PoolDetailView } from "@/components/pool/PoolDetailView";
import type { PoolId } from "@/lib/types";

export const metadata: Metadata = { title: "Pool" };

export default function PoolPage({
  params,
}: {
  params: { poolId: string };
}) {
  return <PoolDetailView poolId={params.poolId as PoolId} />;
}
