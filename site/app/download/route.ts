import { latestRelease, releasesURL } from '@/lib/releases';
import { publicReleasesEnabled } from '@/lib/distribution';
export async function GET(request: Request) {
  if (!publicReleasesEnabled) return Response.redirect(new URL('/#download', request.url), 307);
  try {
    const release = await latestRelease();
    return Response.redirect(release?.archive.browser_download_url || releasesURL, 307);
  } catch {
    return Response.redirect(releasesURL, 307);
  }
}
