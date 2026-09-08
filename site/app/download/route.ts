import { latestRelease, releasesURL } from '@/lib/releases';
export async function GET() {
  try {
    const release = await latestRelease();
    return Response.redirect(release?.archive.browser_download_url || releasesURL, 307);
  } catch {
    return Response.redirect(releasesURL, 307);
  }
}
