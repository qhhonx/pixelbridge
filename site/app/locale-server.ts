import { cache } from 'react';
import { cookies, headers } from 'next/headers';
import { acceptedLanguages, resolveLanguage, type LanguagePreference } from '@/lib/i18n';
export const requestLanguage = cache(async function requestLanguage() {
  const cookie = (await cookies()).get('pixelbridge-language')?.value;
  const preference: LanguagePreference = cookie === 'en' || cookie === 'zh-Hans' ? cookie : 'system';
  const language = resolveLanguage(preference, acceptedLanguages((await headers()).get('accept-language') ?? 'en'));
  return { preference, language };
});
