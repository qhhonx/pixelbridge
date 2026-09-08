/** Enable only after the corresponding releases are publicly accessible. */
export const publicReleasesEnabled = process.env.NEXT_PUBLIC_RELEASES_ENABLED === 'true';
/** Leave unset while the source repository is private. */
export const publicSourceURL = process.env.NEXT_PUBLIC_SOURCE_URL || '';
