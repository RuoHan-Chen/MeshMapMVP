import StoryArticle from "@/components/StoryArticle";

export default function StoryPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  return <StoryArticle params={params} />;
}
