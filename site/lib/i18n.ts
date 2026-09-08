import en from '../locales/en.json';
import zh from '../locales/zh-Hans.json';
export type Language = 'en' | 'zh-Hans';
export type LanguagePreference = Language | 'system';
export type CopyKey = keyof typeof en;
export const catalogs: Record<Language, Record<CopyKey, string>> = { en, 'zh-Hans': zh };
export function resolveLanguage(preference: string | undefined, languages: readonly string[]): Language {
  if (preference === 'en' || preference === 'zh-Hans') return preference;
  return languages[0]?.toLowerCase().startsWith('zh') ? 'zh-Hans' : 'en';
}
export function acceptedLanguages(header: string): string[] {
  return header.split(',').map((entry, order) => {
    const [language, ...parameters] = entry.trim().split(';');
    const quality = parameters.find(p => p.trim().startsWith('q='));
    return { language, order, q: quality ? Number(quality.trim().slice(2)) : 1 };
  }).filter(e => e.language && Number.isFinite(e.q) && e.q > 0 && e.q <= 1)
    .sort((a,b) => b.q - a.q || a.order - b.order).map(e => e.language);
}
