'use client';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { Globe } from 'lucide-react';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { catalogs, resolveLanguage, type CopyKey, type Language, type LanguagePreference } from '@/lib/i18n';
type CopyContext = { t: (key: CopyKey) => string; language: Language; preference: LanguagePreference; choose: (preference: LanguagePreference) => void };
const Context = createContext<CopyContext | null>(null);
export function LanguageProvider({ language: initialLanguage, preference: initialPreference, children }: { language: Language; preference: LanguagePreference; children: ReactNode }) {
  const [language, setLanguage] = useState(initialLanguage);
  const [preference, setPreference] = useState(initialPreference);
  function choose(next: LanguagePreference) {
    setPreference(next);
    setLanguage(resolveLanguage(next, navigator.languages));
    document.cookie = next === 'system'
      ? 'pixelbridge-language=; Path=/; Max-Age=0; SameSite=Lax; Secure'
      : `pixelbridge-language=${next}; Path=/; Max-Age=31536000; SameSite=Lax; Secure`;
  }
  useEffect(() => {
    function update() {
      if (preference === 'system') setLanguage(resolveLanguage('system', navigator.languages));
    }
    update();
    window.addEventListener('languagechange', update);
    return () => window.removeEventListener('languagechange', update);
  }, [preference]);
  useEffect(() => {
    document.documentElement.lang = language;
    document.title = catalogs[language].meta_title;
    document.querySelector('meta[name="description"]')?.setAttribute('content', catalogs[language].meta_description);
  }, [language]);
  return <Context.Provider value={{ language, preference, choose, t: key => catalogs[language][key] }}>{children}</Context.Provider>;
}
export function useCopy() {
  const context = useContext(Context);
  if (!context) throw new Error('LanguageProvider is required');
  return context;
}
export function LanguageSwitch() {
  const { preference, choose, t } = useCopy();
  return <Select value={preference} onValueChange={value => { if (value === 'system' || value === 'en' || value === 'zh-Hans') choose(value); }}>
    <SelectTrigger className="language-switch" aria-label={t('language_label')}><Globe size={15} /><SelectValue>{preference === 'system' ? t('language_system') : preference === 'en' ? 'English' : '中文'}</SelectValue></SelectTrigger>
    <SelectContent className="language-options"><SelectItem value="system">{t('language_system')}</SelectItem><SelectItem value="zh-Hans">中文</SelectItem><SelectItem value="en">English</SelectItem></SelectContent>
  </Select>;
}
