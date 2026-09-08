import { latestRelease } from '@/lib/releases';
export async function GET() {
  try {
    const release = await latestRelease();
    if (!release) throw new Error('No complete release');
    const response = await fetch(release.appcast.browser_download_url, { next: { revalidate: 300 }, signal: AbortSignal.timeout(10_000) });
    if (!response.ok) throw new Error('Feed unavailable');
    // Preserve every signed byte; never rebuild or reformat the upstream XML.
    return new Response(await response.arrayBuffer(), { headers: {
      'Content-Type': 'application/rss+xml; charset=utf-8', 'Cache-Control': 'public, max-age=60, s-maxage=300',
      'X-Content-Type-Options': 'nosniff',
    }});
  } catch {
    return new Response('Update service temporarily unavailable. Please try again later.', { status: 503, headers: { 'Cache-Control': 'no-store', 'Retry-After': '60' } });
  }
}
