import Home from './home';
import { LanguageProvider } from './language';
import { requestLanguage } from './locale-server';
export const dynamic = 'force-dynamic';
export default async function Page() {
  const locale = await requestLanguage();
  return <LanguageProvider {...locale}><Home /></LanguageProvider>;
}
