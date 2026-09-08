'use client';

import Image from 'next/image';
import { useCopy, LanguageSwitch } from './language';
import { ArrowRight, ArrowUpRight, Check, CheckCircle2, Cloud, Download, Folder, HardDrive, Images, Layers3, Monitor, RefreshCw, Settings2, ShieldCheck, Smartphone, Usb, Wifi } from 'lucide-react';
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion';

const repository = process.env.NEXT_PUBLIC_REPOSITORY_URL || 'https://github.com/qhhonx/pixelbridge';
const download = '/download';


function Photo({ index, className = '' }: { index: number; className?: string }) {
  const { t } = useCopy();
  return <div className={`photo photo-${index} ${className}`} ><Image unoptimized src="/assets/memories.png" width={1536} height={1024} alt={[t('photo_coast_alt'),t('photo_lake_alt'),t('photo_desert_alt'),t('photo_forest_alt'),t('photo_sunset_alt'),t('photo_mountain_alt')][index]} /></div>;
}

export default function Home() {
  const { t } = useCopy();
  const faqs = [
  [t('faq_pixel_question'), <>{t('faq_pixel_answer')}<a href="https://support.google.com/pixelphone/answer/6220791?hl=zh-Hans" target="_blank" rel="noreferrer">{t('faq_pixel_link')}</a></>],
  [t('faq_icloud_question'), t('faq_icloud_answer')],
  [t('faq_motion_question'), t('faq_motion_answer')],
  [t('faq_cleanup_question'), t('faq_cleanup_answer')],
  [t('faq_dedup_question'), t('faq_dedup_answer')],
  [t('faq_overnight_question'), t('faq_overnight_answer')],
  [t('faq_progress_question'), t('faq_progress_answer')],
];
  return <>
    <a className="skip-link" href="#main">{t('accessibility_skip')}</a>
    <header className="header"><nav className="nav wrap" aria-label={t('accessibility_navigation')}>
      <a className="brand" href="#main"><Image unoptimized src="/assets/pixelbridge.png" width="38" height="38" alt="" /><span>PixelBridge</span></a>
      <div className="nav-links"><a href="#features">{t('nav_features')}</a><a href="#how">{t('nav_how')}</a><a href="#guide">{t('nav_guide')}</a><a href="#faq">{t('nav_faq')}</a></div>
      <LanguageSwitch /><a className="nav-download" href="#download">{t('nav_download')}<ArrowUpRight size={16} /></a>
    </nav></header>
    <main id="main">
      <section className="hero wrap">
        <div className="eyebrow"><span className="status-dot" /> {t('hero_eyebrow')}</div>
        <h1>{t('hero_title_first')}<br /><span>{t('hero_title_second')}</span></h1>
        <p className="hero-copy">{t('hero_description_first')}<br className="desktop-break" />{t('hero_description_second')}</p>
        <div className="hero-actions"><a className="button primary" href="#download"><Download size={19} /> {t('hero_download')}</a><a className="text-link" href="#how">{t('hero_how')}<ArrowRight size={18} /></a></div>
        <p className="compatibility">{t('hero_compatibility')}</p>
        <figure className="app-figure">
          <div className="app-window">
            <aside className="app-sidebar"><div className="traffic" aria-hidden="true"><i /><i /><i /></div><div className="app-mini-brand"><Image unoptimized src="/assets/pixelbridge.png" width="26" height="26" alt="" /> PixelBridge</div><span className="sidebar-caption">{t('sidebar_photos')}</span><span className="sidebar-item selected"><Images size={16} /> {t('nav_library')}</span><span className="sidebar-item"><Layers3 size={16} /> {t('nav_overview')}</span><span className="sidebar-item"><RefreshCw size={16} /> {t('nav_tasks')}</span><span className="sidebar-caption management">{t('sidebar_management')}</span><span className="sidebar-item"><Smartphone size={16} /> {t('nav_device')}</span><span className="sidebar-item"><Settings2 size={16} /> {t('nav_settings')}</span><span className="sidebar-bottom"><span className="status-dot" /> {t('status_automatic')}</span></aside>
            <div className="app-main"><div className="app-toolbar"><b>{t('nav_library')}</b><span>{t('mock_label')}</span></div><div className="gallery-heading"><div><h2>{t('gallery_heading')}</h2><p>{t('mock_gallery_count')}</p></div><span className="gallery-filter">{t('media_all')}</span></div><div className="photo-grid">{[0,1,2,3,4,5].map((i)=><div className="photo-cell" key={i}><Photo index={i} />{[0,1,4].includes(i)&&<span className="live-label">{t('media_motion_badge')}</span>}</div>)}</div><div className="transfer-line"><Photo index={0} /><div><strong>{t('mock_transfer_title')}</strong><span>{t('mock_transfer_description')}</span></div><span className="transfer-chip"><ShieldCheck size={14} /> {t('mock_transfer_check')}</span></div></div>
          </div>
          <figcaption>{t('mock_caption')}</figcaption>
        </figure>
      </section>

      <div className="trust-strip wrap"><span><Monitor /> {t('trust_native')}</span><span><RefreshCw /> {t('trust_incremental')}</span><span><ShieldCheck /> {t('trust_verification')}</span><span><HardDrive /> {t('trust_cleanup')}</span></div>

      <section className="section wrap" id="features"><div className="section-heading"><p className="kicker">{t('features_kicker')}</p><h2>{t('features_title_first')}<br />{t('features_title_second')}</h2><p>{t('features_description_first')}<br />{t('features_description_second')}</p></div>
        <div className="feature-grid"><article><span className="feature-icon"><Images /></span><h3>{t('feature_habits_title')}</h3><p>{t('feature_habits_description')}</p><span className="feature-note">{t('feature_habits_note')}</span></article><article><span className="feature-icon"><Layers3 /></span><h3>{t('feature_motion_title')}</h3><p>{t('feature_motion_description')}</p><span className="feature-note">{t('feature_motion_note')}</span></article><article><span className="feature-icon"><RefreshCw /></span><h3>{t('feature_resume_title')}</h3><p>{t('feature_resume_description')}</p><span className="feature-note">{t('feature_resume_note')}</span></article></div>
      </section>

      <section className="flow-section" id="how"><div className="wrap"><div className="section-heading compact"><p className="kicker">{t('flow_kicker')}</p><h2>{t('flow_title')}</h2><p>{t('flow_description')}</p></div><div className="flow-grid">
        <article><span className="flow-icon apple-cloud"><Cloud /></span><h3>{t('flow_source_title')}</h3><p>{t('flow_source_description')}</p><small>{t('flow_source_note')}</small></article><ArrowRight className="flow-arrow" /><article><span className="flow-icon"><Image unoptimized src="/assets/pixelbridge.png" alt="PixelBridge" width="62" height="62" /></span><h3>Mac · PixelBridge</h3><p>{t('flow_mac_description')}</p><small>{t('flow_mac_note')}</small></article><ArrowRight className="flow-arrow" /><article><span className="flow-icon pixel-icon"><Smartphone /></span><h3>{t('flow_pixel_title')}</h3><p>{t('flow_pixel_description')}</p><small>{t('flow_pixel_note')}</small></article><ArrowRight className="flow-arrow" /><article><span className="flow-icon google-cloud"><Cloud /></span><h3>Google Photos</h3><p>{t('flow_cloud_description')}</p><small>{t('flow_cloud_note')}</small></article>
      </div><div className="flow-note"><ShieldCheck size={20} /><p><strong>{t('flow_notice_title')}</strong> {t('flow_notice_description')}</p></div></div></section>

      <section className="section wrap guide-section" id="guide"><div className="guide-intro"><p className="kicker">{t('guide_kicker')}</p><h2>{t('guide_title_first')}<br />{t('guide_title_second')}</h2><p>{t('guide_description_first')}<br />{t('guide_description_second')}</p><div className="requirements"><h3>{t('requirements_title')}</h3><span><Check /> {t('requirements_mac')}</span><span><Check /> {t('requirements_pixel')}</span><span><Usb /> {t('requirements_usb')}</span><span><Wifi /> {t('requirements_network')}</span></div></div><ol className="steps">
        <li><span className="step-number">01</span><div><h3>{t('step_install_title')}</h3><p>{t('step_install_description')}</p></div></li>
        <li><span className="step-number">02</span><div><h3>{t('step_connect_title')}</h3><p>{t('step_connect_description')}</p></div></li>
        <li><span className="step-number">03</span><div><h3>{t('step_sample_title')}</h3><p>{t('step_sample_description')}</p></div></li>
        <li><span className="step-number">04</span><div><h3>{t('step_automatic_title')}</h3><p>{t('step_automatic_description')}</p><span className="step-hint">{t('step_automatic_hint')}</span></div></li>
      </ol></section>

      <section className="care-section wrap" id="notes"><div className="care-heading"><p className="kicker">{t('care_kicker')}</p><h2>{t('care_title_first')}<br />{t('care_title_second')}</h2><p>{t('care_description')}</p></div><div className="care-grid"><article><HardDrive /><h3>{t('care_cache_title')}</h3><p>{t('care_cache_description')}</p></article><article><Smartphone /><h3>{t('care_pixel_title')}</h3><p>{t('care_pixel_description')}</p></article><article><ShieldCheck /><h3>{t('care_protection_title')}</h3><p>{t('care_protection_description')}</p></article><article><Folder /><h3>{t('care_progress_title')}</h3><p>{t('care_progress_description')}</p></article></div><p className="honest-note"><CheckCircle2 size={18} /> {t('care_honest_note')}</p></section>

      <section className="section wrap faq-section" id="faq"><div><p className="kicker">{t('faq_kicker')}</p><h2>{t('faq_title')}</h2><p>{t('faq_description_first')}<br />{t('faq_description_second')}</p></div><Accordion className="faqs">{faqs.map(([question,answer],i)=><AccordionItem value={`faq-${i}`} key={i}><AccordionTrigger className="faq-question">{question}</AccordionTrigger><AccordionContent className="faq-answer">{answer}</AccordionContent></AccordionItem>)}</Accordion></section>

      <section className="download-section wrap" id="download"><div className="download-content"><Image unoptimized src="/assets/pixelbridge.png" width="72" height="72" alt={t('brand_icon_alt')} /><p className="kicker">{t('download_kicker')}</p><h2>{t('download_title')}</h2><p>{t('download_description')}</p><a className="button primary" href={download} download><Download size={20} /> {t('download_action')}<ArrowUpRight size={18} /></a><span className="download-meta">{t('download_metadata')}</span><p className="beta-note">{t('download_beta_notice')}<br />{t('download_validation_notice')}</p><p className="beta-note">{t('download_install_notice')}</p><p className="beta-note"><a href="https://support.apple.com/en-us/102445" target="_blank" rel="noreferrer">{t('download_install_help')}</a> · <a href={repository} target="_blank" rel="noreferrer">{t('download_source')}</a></p></div></section>
    </main>
    <footer className="footer wrap"><div><a className="brand" href="#main"><Image unoptimized src="/assets/pixelbridge.png" width="30" height="30" alt="" /><span>PixelBridge</span></a><p>{t('footer_description')}</p></div><div className="footer-right"><a href="#guide">{t('nav_guide')}</a><a href="#notes">{t('nav_notes')}</a><a href="https://support.google.com/pixelphone/answer/6220791?hl=zh-Hans" target="_blank" rel="noreferrer">{t('footer_google_policy')}</a><p>{t('footer_independent')}<br />{t('footer_policy_notice')}</p></div></footer>
  </>;
}
