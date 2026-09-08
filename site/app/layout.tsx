import type { Metadata } from 'next';
import { catalogs } from '@/lib/i18n';
import { requestLanguage } from './locale-server';
import './globals.css';
export async function generateMetadata(): Promise<Metadata> {
  const { language } = await requestLanguage();
  return {
    metadataBase: new URL(process.env.SITE_URL || (process.env.VERCEL_PROJECT_PRODUCTION_URL ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}` : 'http://localhost:3000')),
    title: catalogs[language].meta_title,
    description: catalogs[language].meta_description,
    icons: { icon: '/assets/pixelbridge.png', apple: '/assets/pixelbridge.png' },
  };
}
export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const { language } = await requestLanguage();
  return <html lang={language}><body>{children}</body></html>;
}
