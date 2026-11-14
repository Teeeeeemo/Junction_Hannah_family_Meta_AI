import { useCallback, useEffect, useRef, useState } from 'react';
import { App as WearableApp, Button as WearableButton } from '@wearables-ui-toolkit/mrbd';
import type { Analysis, Box, Detail, Language, QuestionResponse } from './contracts';
import { createTracker, drawDemoScene, projectBox } from './vision';
import type { Tracker } from './vision';
import { LiveAudioClient, setBrowserSpeechRate, speakBrowser, stopBrowserSpeech, unlockAudio } from './audio';
import { sentencesOf } from './captions';
import { cameraFailure, hasVideoFrame, openBrowserVideo, type CameraFailure } from './camera-input';
import { PLAYBACK_RATES, isPlaybackRate, parseSpeedCommand, remainingNarration, type PlaybackRate } from './playback-speed';
import './app.css';

type Phase = 'ready' | 'analyzing' | 'overview' | 'details' | 'paused' | 'answering' | 'error';
type InputKind = 'image' | 'video' | 'camera';
const W = 640;
const cn = (language: Language, en: string, zh: string) => language === 'zh' ? zh : en;
const t = {
  en: { start:'Begin your visit', demo:'Explore offline demo', title:'Look closer.', subtitle:'Every detail has a story.', intro:'A quieter way to discover art.', overview:'The whole story', points:'LOOK CLOSER', analyzing:'Looking at the artwork…', pause:'Pause', resume:'Continue', next:'Next detail', ask:'Ask a question', settings:'Visit settings', sources:'Sources', ending:'Your exploration, at your pace.', mic:'Talk to your guide', done:'You have explored every detail.', question:'Why does this detail matter?', input:'Your perspective', noKey:'Gemini key not configured', keyReady:'Gemini ready', ready:'Ready to explore', track:'Tracking', lost:'Reacquiring artwork', muted:'Browser voice', live:'Gemini Live voice', speak:'Speaking', now:'NOW EXPLORING', image:'Artwork image', video:'Upload video', camera:'Use camera', upload:'Upload artwork', motion:'Simulated head movement', overlay:'Overlay only', stop:'End visit', fail:'Please try again', skip:'Go to details', fullscreen:'Full screen' },
  zh: { start:'开始导览', demo:'体验离线演示', title:'看见更多。', subtitle:'每一处细节，都有故事。', intro:'以自己的节奏，走近艺术。', overview:'先认识这幅作品', points:'细节探索', analyzing:'正在观察作品…', pause:'暂停', resume:'继续', next:'下一个细节', ask:'问个问题', settings:'导览设置', sources:'资料来源', ending:'跟随你的好奇心，慢慢探索。', mic:'与导览员对话', done:'你已探索全部细节点。', question:'这个细节有什么意义？', input:'你的视角', noKey:'尚未配置 Gemini 密钥', keyReady:'Gemini 已就绪', ready:'准备开始探索', track:'持续追踪', lost:'正在重新定位作品', muted:'浏览器语音', live:'Gemini Live 语音', speak:'正在讲解', now:'当前讲解', image:'作品图片', video:'上传视频', camera:'使用摄像头', upload:'上传作品', motion:'模拟头部移动', overlay:'仅显示叠加界面', stop:'结束导览', fail:'请重试', skip:'进入细节', fullscreen:'全屏' }
};
async function post<T>(url: string, body: unknown): Promise<T> {
  const response = await fetch(url, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || data.error?.message || data.error || `Request failed (${response.status})`);
  return data;
}
function snapshot(source: CanvasImageSource, width: number, height: number, max = 1000) {
  const scale = Math.min(1, max / Math.max(width, height));
  const canvas = document.createElement('canvas'); canvas.width = Math.round(width * scale); canvas.height = Math.round(height * scale);
  canvas.getContext('2d')!.drawImage(source, 0, 0, canvas.width, canvas.height); return canvas;
}
function contain(ctx: CanvasRenderingContext2D, source: CanvasImageSource, width: number, height: number) {
  const scale = Math.min(W / width, W / height), x = (W - width * scale) / 2, y = (W - height * scale) / 2;
  ctx.drawImage(source, x, y, width * scale, height * scale);
  return [scale, 0, x, 0, scale, y, 0, 0, 1];
}
function bounds(points: number[][]) {
  const xs = points.map(p => p[0]), ys = points.map(p => p[1]);
  return { x:Math.min(...xs), y:Math.min(...ys), w:Math.max(...xs)-Math.min(...xs), h:Math.max(...ys)-Math.min(...ys) };
}

export default function App() {
  const [language, setLanguage] = useState<Language>('en');
  const strings = t[language];
  const [config, setConfig] = useState<{ configured:boolean; model?:string; liveModel?:string } | null>(null);
  const [phase, setPhase] = useState<Phase>('ready');
  const [analysis, setAnalysis] = useState<Analysis | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [seen, setSeen] = useState<string[]>([]);
  const [inputKind, setInputKind] = useState<InputKind>('camera');
  const [imageUrl, setImageUrl] = useState('');
  const [cameraStatus, setCameraStatus] = useState<'idle'|'requesting'|'ready'|CameraFailure>('idle');
  const [imageReady, setImageReady] = useState(false);
  const [motion, setMotion] = useState(false);
  const [overlayOnly, setOverlayOnly] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [playbackRate, setPlaybackRate] = useState<PlaybackRate>(1);
  const [poly, setPoly] = useState<number[][] | null>(null);
  const [tracking, setTracking] = useState('ready');
  const [question, setQuestion] = useState('');
  const [caption, setCaption] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [sourcesOpen, setSourcesOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [micOn, setMicOn] = useState(false);
  const [speaking, setSpeaking] = useState(false);
  const [voiceMode, setVoiceMode] = useState<'browser' | 'live'>('browser');
  const [demo, setDemo] = useState(false);
  const [focusIndex, setFocusIndex] = useState(0);
  const [languageChanging, setLanguageChanging] = useState(false);
  const stageRef = useRef<HTMLDivElement>(null);
  const sceneRef = useRef<HTMLCanvasElement>(null);
  const zoomRef = useRef<HTMLCanvasElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const uploadRef = useRef<HTMLInputElement>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const cameraRef = useRef<MediaStream | null>(null);
  const trackerRef = useRef<Tracker | null>(null);
  const analysisRef = useRef<Analysis | null>(null);
  const selectedRef = useRef<string | null>(null);
  const languageRef = useRef<Language>('en');
  const zoomValue = useRef(1);
  const phaseRef = useRef<Phase>('ready');
  const runRef = useRef(0);
  const liveRef = useRef<LiveAudioClient | null>(null);
  const modelReference = useRef<{ width:number; height:number } | null>(null);
  const selectRef = useRef<(detail: Detail, autoplay?: boolean, text?: string) => void>(() => {});
  const speedRef = useRef<PlaybackRate>(1);
  const speakingRef = useRef(false);
  const voiceResumeRef = useRef(false);
  const resumeRef = useRef<() => void>(() => {});
  const narrationRef = useRef<{ text: string; sentence: string; detailId: string | null } | null>(null);
  const questionRef = useRef<(text: string) => Promise<void>>(async () => {});
  const autoRef = useRef(true);
  const analyzedDemo = useRef(false);
  const pendingTranscript = useRef('');
  const transcriptTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const completedRef = useRef(new Set<string>());
  const inputGeneration = useRef(0);
  const durationRef = useRef(0);
  const lastReadId = useRef('');
  const lossPausedRef = useRef(false);
  const trackedPointRef = useRef<{ id: string; at: number } | null>(null);
  const languageSwitchRef = useRef(0);
  const analysisLanguageRef = useRef<Language>('en');
  const detailButtonRefs = useRef<(HTMLButtonElement | null)[]>([]);

  useEffect(() => { languageRef.current = language; }, [language]);
  useEffect(() => { phaseRef.current = phase; }, [phase]);
  useEffect(() => { selectedRef.current = selectedId; }, [selectedId]);
  useEffect(() => { zoomValue.current = zoom; }, [zoom]);
  useEffect(() => {
    fetch('/api/config').then(r => r.json()).then(setConfig).catch(() => setConfig({ configured:false }));
    const timer = setInterval(() => fetch('/api/config').then(r=>r.json()).then(setConfig).catch(()=>{}), 15000);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => {
    if(!imageUrl){imageRef.current=null;setImageReady(false);return;}
    const image = new Image(); image.onload = () => { imageRef.current = image; setImageReady(true); };
    image.onerror = () => { setError(cn(languageRef.current,'Could not load the artwork. Upload an image to continue.','无法读取作品图片，请上传一张图片。')); setImageReady(false); };
    setImageReady(false); image.src = imageUrl;
    return () => { image.onload = null; };
  }, [imageUrl]);

  const pauseTour = useCallback(() => {
    ++runRef.current; autoRef.current = false; stopBrowserSpeech(); setSpeaking(false); speakingRef.current=false;
    if (analysisRef.current) setPhase('paused');
  }, []);
  const interrupt = useCallback(() => {
    liveRef.current?.interrupt(); pauseTour();
  }, [pauseTour]);
  const changePlaybackSpeed = useCallback((rate: number) => {
    if (!isPlaybackRate(rate)) return;
    speedRef.current=rate; setPlaybackRate(rate);
    liveRef.current?.setPlaybackRate(rate); setBrowserSpeechRate(rate);
  }, []);
  const cleanupInput = useCallback(() => {
    ++inputGeneration.current;
    cameraRef.current?.getTracks().forEach(track => track.stop()); cameraRef.current = null;
    videoRef.current?.pause(); if(videoRef.current) videoRef.current.srcObject = null;
    videoRef.current=null;
    trackerRef.current?.dispose(); trackerRef.current = null;
  }, []);
  const reset = useCallback(() => {
    ++languageSwitchRef.current; setLanguageChanging(false);
    interrupt(); liveRef.current?.disconnect(); liveRef.current = null; setMicOn(false); setVoiceMode('browser');
    analysisRef.current = null; setAnalysis(null); selectedRef.current = null; setSelectedId(null); setPoly(null); setZoom(1);
    narrationRef.current=null; voiceResumeRef.current=false;
    completedRef.current.clear(); setSeen([]); setCaption(''); setError(''); setNotice(''); setPhase('ready'); lastReadId.current='';
    trackerRef.current?.dispose(); trackerRef.current = null; setSourcesOpen(false); setSettingsOpen(false);
  }, [interrupt]);

  useEffect(() => {
    let frame = 0, last = 0, start = performance.now();
    const draw = (now: number) => {
      const canvas = sceneRef.current, ctx = canvas?.getContext('2d');
      if (!canvas || !ctx) { frame=requestAnimationFrame(draw); return; }
      ctx.fillStyle='#14140f'; ctx.fillRect(0,0,W,W);
      let H: number[] | null = null;
      let rw = W, rh = W;
      if (inputKind === 'image' && imageRef.current && imageReady) {
        const image=imageRef.current; rw=image.naturalWidth; rh=image.naturalHeight;
        H = motion ? drawDemoScene(ctx,image,(now-start)/1000) : contain(ctx,image,rw,rh);
      } else if (videoRef.current && videoRef.current.readyState >= 2) {
        contain(ctx,videoRef.current,videoRef.current.videoWidth,videoRef.current.videoHeight);
      }
      if (now-last >= 90) {
        last=now; let points: number[][] | null=null;
        const data=analysisRef.current, detail=data?.details.find(d=>d.id===selectedRef.current);
        if (detail) {
          if (inputKind==='image' && H) {
            points=projectBox(detail.box,H,rw,rh); setTracking(motion?'synthetic':'image');
          } else if (trackerRef.current) {
            try {
              const result=trackerRef.current.update(canvas);
              if(result.status==='tracking') points=trackerRef.current.project(detail.box);
              setTracking(result.status);
            } catch { setTracking('lost'); }
          }
          setPoly(points);
          trackedPointRef.current=points ? {id:detail.id,at:now} : null;
          if (!points && inputKind !== 'image' && phaseRef.current === 'details' && !lossPausedRef.current) {
            lossPausedRef.current = true; interrupt();
            setNotice(cn(languageRef.current, 'Tracking lost. Reframe the artwork, then press Continue.', '追踪暂时丢失。请重新对准作品，再按继续。'));
          }
          const z=zoomRef.current, zctx=z?.getContext('2d');
          if(z && zctx) {
            zctx.fillStyle='#10110d'; zctx.fillRect(0,0,z.width,z.height);
            if(points) {
              const b=bounds(points), factor=zoomValue.current;
              const size=Math.max(b.w,b.h)*1.65/factor;
              const sx=b.x+b.w/2-size/2, sy=b.y+b.h/2-size/2;
              zctx.drawImage(canvas,sx,sy,size,size,0,0,z.width,z.height);
            }
          }
        } else { setPoly(null); trackedPointRef.current=null; setTracking(inputKind==='image'?(motion?'synthetic':'image'):'ready'); }
      }
      frame=requestAnimationFrame(draw);
    };
    frame=requestAnimationFrame(draw);
    return()=>cancelAnimationFrame(frame);
  },[inputKind,imageReady,motion,interrupt]);

  useEffect(()=>()=>{ cleanupInput(); liveRef.current?.disconnect(); stopBrowserSpeech(); if(transcriptTimer.current)clearTimeout(transcriptTimer.current); },[cleanupInput]);

  const narrate = useCallback(async (text: string, token: number) => {
    const first=sentencesOf(text)[0] || text;
    narrationRef.current={text,sentence:first,detailId:selectedRef.current};
    setCaption(first); setSpeaking(true); speakingRef.current=true;
    if(liveRef.current?.ready) await liveRef.current.say(text);
    else { setBrowserSpeechRate(speedRef.current); await speakBrowser(text,languageRef.current,sentence=>{if(token===runRef.current){setCaption(sentence);if(narrationRef.current)narrationRef.current.sentence=sentence;}}); }
    if(token===runRef.current) {setSpeaking(false);speakingRef.current=false;}
  },[]);

  const selectDetail = useCallback(async (detail: Detail, autoplay = true, text?: string) => {
    const token=++runRef.current; liveRef.current?.interrupt(); stopBrowserSpeech(); setSpeaking(false); speakingRef.current=false;
    selectedRef.current=detail.id; setSelectedId(detail.id); setPoly(null); trackedPointRef.current=null; lossPausedRef.current=false; lastReadId.current=detail.id; setFocusIndex(detail.number-1);
    setPhase('details'); setSourcesOpen(false); autoRef.current=autoplay;
    const deadline=performance.now()+1800;
    const pointReady=()=>((trackedPointRef.current as {id:string;at:number}|null)?.id===detail.id);
    while(token===runRef.current && !pointReady() && performance.now()<deadline)await new Promise(resolve=>setTimeout(resolve,40));
    if(token!==runRef.current)return;
    if(!pointReady()){autoRef.current=false;setPhase('paused');setNotice(cn(languageRef.current,'Reframe this point before continuing its narration.','请先重新对准此点位，再继续讲解。'));return;}
    liveRef.current?.setContext(analysisRef.current!,detail.id);
    if(liveRef.current?.ready && sceneRef.current) liveRef.current.image(sceneRef.current.toDataURL('image/jpeg',.7));
    await narrate(text || detail.description,token);
    if(token!==runRef.current) return;
    completedRef.current.add(detail.id); setSeen([...completedRef.current]);
    if(autoRef.current) {
      const list=analysisRef.current?.details||[], index=list.findIndex(d=>d.id===detail.id), next=list.slice(index+1).find(d=>!completedRef.current.has(d.id));
      if(next) { await new Promise(resolve=>setTimeout(resolve,1100)); if(token===runRef.current&&autoRef.current) selectRef.current(next,true); }
    }
  },[narrate]);
  useEffect(()=>{selectRef.current=(detail,autoplay=true,text)=>{void selectDetail(detail,autoplay,text);};},[selectDetail]);

  const ensureLive = async (data: Analysis) => {
    if(data.mode==='demo')return;
    const live=new LiveAudioClient({
      onTranscript:(role,text)=>{
        if(role==='user') { setCaption(text); pendingTranscript.current=text; }
        else if(role==='model'||role==='assistant'){setCaption(text);if(narrationRef.current)narrationRef.current.sentence=text;}
      },
      onInterrupt:()=>{voiceResumeRef.current ||= speakingRef.current;pauseTour();},
      onCommand:(number)=>{const d=analysisRef.current?.details.find(p=>p.number===number);if(d)selectRef.current(d,false);},
      onSpeedChange:rate=>{changePlaybackSpeed(rate);const shouldResume=voiceResumeRef.current;voiceResumeRef.current=false;if(shouldResume)resumeRef.current();},
      onTurnComplete:()=>{voiceResumeRef.current=false;},
      onError:message=>setNotice(`${cn(languageRef.current,'Voice: ','语音：')}${message}`)
    });
    live.setPlaybackRate(speedRef.current);
    liveRef.current=live;
    try {
      await live.connect(data,languageRef.current);
      if(liveRef.current!==live){live.disconnect();return;}
      live.setContext(data,selectedRef.current||undefined);setVoiceMode('live');
    }
    catch(e) {
      live.disconnect();
      if(liveRef.current!==live)return;
      liveRef.current=null; setVoiceMode('browser'); setNotice(cn(languageRef.current,'Gemini Live unavailable. Narration uses browser voice; type questions below.','Gemini Live 暂不可用。讲解使用浏览器语音，可在下方输入追问。'));
    }
  };

  const startTour = async (isDemo: boolean) => {
    if(phase==='analyzing'||cameraStatus==='requesting')return;
    if(inputKind==='camera'&&!hasVideoFrame(videoRef.current)) {if(!await useCamera())return;}
    if(!sceneRef.current || !imageReady && inputKind==='image')return;
    if(inputKind!=='image'&&!hasVideoFrame(videoRef.current)){setError(cn(languageRef.current,'Waiting for a decoded video frame. Keep the artwork in view and try again.','正在等待真实视频帧，请保持对准作品后重试。'));return;}
    await unlockAudio().catch(()=>{}); reset(); analyzedDemo.current=isDemo; setDemo(isDemo); setPhase('analyzing'); const token=++runRef.current;
    try {
      const image=imageRef.current;
      const video=videoRef.current;
      const reference=inputKind==='image'&&image ? snapshot(image,image.naturalWidth,image.naturalHeight) : snapshot(video!,video!.videoWidth,video!.videoHeight);
      modelReference.current={width:reference.width,height:reference.height};
      const result=await post<Analysis>('/api/analyze',{image:reference.toDataURL('image/jpeg',.85),language:languageRef.current,artworkId: inputKind==='image'&&imageUrl==='/artworks/wheat-field.jpg'?'met-436535':undefined,demo:isDemo});
      if(token!==runRef.current)return;
      result.details=result.details.map((d,i)=>({...d,number:i+1}));
      if(!result.details.length)throw new Error(cn(languageRef.current,'No reliable details found. Try a clearer artwork image.','没有找到可靠的细节点，请尝试更清晰的画面。'));
      analysisLanguageRef.current=languageRef.current; analysisRef.current=result; setAnalysis(result); setPhase('overview');
      if(inputKind!=='image') {
        setTracking('loading');
        void createTracker(reference).then(tracker=>{if(token===runRef.current || analysisRef.current===result){trackerRef.current?.dispose();trackerRef.current=tracker;}else tracker.dispose();}).catch(e=>setNotice(`Tracking: ${e.message}`));
      }
      await ensureLive(result);
      if(token!==runRef.current)return;
      await narrate(result.overview,token);
      if(token===runRef.current)selectRef.current(result.details[0],true);
    } catch(e) { if(token===runRef.current){setError(e instanceof Error?e.message:String(e));setPhase('error');} }
  };
  const resume = () => {
    const data=analysisRef.current; if(!data||languageChanging)return;
    const detail=data.details.find(d=>d.id===selectedRef.current);
    const previous=narrationRef.current;
    const remaining=previous?.detailId===selectedRef.current?remainingNarration(detail?.description||data.overview,previous.sentence):undefined;
    if(detail){selectRef.current(detail,true,remaining);return;}
    liveRef.current?.interrupt();stopBrowserSpeech();
    const token=++runRef.current;setPhase('overview');
    void narrate(remaining||data.overview,token).then(()=>{if(token===runRef.current)selectRef.current(data.details[0],true);});
  };
  useEffect(()=>{resumeRef.current=resume;});
  const next = () => {
    const data=analysisRef.current;if(!data)return;
    const index=data.details.findIndex(d=>d.id===selectedRef.current);
    const detail=data.details.slice(index+1).find(d=>!completedRef.current.has(d.id))||data.details[index+1];
    if(detail)selectRef.current(detail,true);else {interrupt();setCaption(t[languageRef.current].done);}
  };
  const changeLanguage = async (lang: Language) => {
    if(lang===languageRef.current && (!analysisRef.current || analysisLanguageRef.current===lang))return;
    interrupt();setLanguage(lang);languageRef.current=lang;
    const original=analysisRef.current;
    if(!original)return;
    const requestId=++languageSwitchRef.current, token=runRef.current, selectedAtStart=selectedRef.current;
    liveRef.current?.disconnect();liveRef.current=null;setMicOn(false);setVoiceMode('browser');
    setLanguageChanging(true);setError('');
    setNotice(cn(lang,'Translating your guide. Point numbers and tracking stay unchanged.','正在切换讲解语言，点位编号和追踪位置保持不变。'));
    try {
      const translated=await post<Analysis>('/api/translate',{analysis:original,language:lang,demo:analyzedDemo.current});
      if(requestId!==languageSwitchRef.current || languageRef.current!==lang || !analysisRef.current || analysisRef.current.artwork.id!==original.artwork.id)return;
      if(translated.details.length!==original.details.length || original.details.some((point,i)=>translated.details[i]?.id!==point.id || translated.details[i]?.number!==point.number || translated.details[i]?.box.some((v,j)=>Math.abs(v-point.box[j])>1e-8)))throw new Error('Translation changed point identifiers or geometry.');
      analysisRef.current=translated;analysisLanguageRef.current=lang;setAnalysis(translated);
      narrationRef.current=null;
      if(token===runRef.current && selectedRef.current===selectedAtStart){
        setCaption(translated.details.find(point=>point.id===selectedAtStart)?.description || translated.overview);
        setPhase('paused');
      }
      setNotice(cn(lang,'Guide translated. Continue the current point when ready.','讲解语言已切换，可继续当前点位。'));
      await ensureLive(translated);
    } catch(e) {
      if(requestId===languageSwitchRef.current && languageRef.current===lang){
        setError(cn(lang,'Guide translation failed; interface language changed, but artwork text is unchanged. Try the language button again. ','讲解翻译失败：界面语言已切换，作品文本仍保留原语言。可再次点击语言按钮重试。')+(e instanceof Error?e.message:String(e)));
        setNotice('');
      }
    } finally {if(requestId===languageSwitchRef.current)setLanguageChanging(false);}
  };

  const askQuestion=async (text: string) => {
    text=text.trim();const data=analysisRef.current;if(!text||!data)return;
    const speed=parseSpeedCommand(text,speedRef.current);
    if(speed!==null){changePlaybackSpeed(speed);setQuestion('');return;}
    interrupt();setQuestion('');setError('');setCaption(text);
    const local=text.match(/(?:point|detail|number|第|讲|看|选)\s*([1-9一二三四五六七八九])/i) || text.match(/^([1-9])$/);
    if(local){const n=/\d/.test(local[1])?Number(local[1]):'一二三四五六七八九'.indexOf(local[1])+1;const detail=data.details.find(d=>d.number===n);if(detail){selectRef.current(detail,false);return;}setNotice(cn(languageRef.current,`Choose a point from 1 to ${data.details.length}.`,`请选择 1 至 ${data.details.length} 号点位。`));return;}
    const named=data.details.find(d=>d.title.length>1&&text.toLowerCase().includes(d.title.toLowerCase()));
    if(named && /show|tell me about|select|讲|选择|看看/i.test(text)){selectRef.current(named,false);return;}
    if(/^(pause|stop|暂停|停止)[.!。]?$/i.test(text))return;
    if(/^(continue|resume|继续)[.!。]?$/i.test(text)){resume();return;}
    if(/^(next|next detail|下一个|下一个细节)[.!。]?$/i.test(text)){next();return;}
    const zoomMatch=text.match(/([124])\s*(?:x|×|times|倍)|(?:zoom\s*(?:in\s*)?)?(one|two|four)\s*times|(?:放大\s*)?([一二两四])\s*倍/i);
    if(zoomMatch){const value=Number(zoomMatch[1])||({one:1,two:2,four:4,一:1,二:2,两:2,四:4} as Record<string,number>)[(zoomMatch[2]||zoomMatch[3]).toLowerCase()];setZoom(value);return;}
    setPhase('answering');const token=++runRef.current;
    try {
      const response=await post<QuestionResponse>('/api/question',{question:text,language:languageRef.current,analysis:data,currentDetailId:selectedRef.current,demo:analyzedDemo.current});
      if(token!==runRef.current)return;
      if(response.selectedDetailId){const d=data.details.find(p=>p.id===response.selectedDetailId);if(d){selectRef.current(d,false);return;}}
      if(response.command==='next'){next();return;}
      if(response.command==='resume'){resume();return;}
      if(response.command==='zoom'&&[1,2,4].includes(response.zoom||0))setZoom(response.zoom!);
      await narrate(response.answer,token);
      if(token===runRef.current)setPhase('paused');
    }catch(e){if(token===runRef.current){setError(e instanceof Error?e.message:String(e));setPhase('paused');}}
  };
  useEffect(()=>{questionRef.current=askQuestion;});

  const toggleMic=async()=>{
    if(micOn){liveRef.current?.stopMicrophone();setMicOn(false);return;}
    if(!analysisRef.current)return;
    interrupt();
    if(analyzedDemo.current){setNotice(cn(languageRef.current,'Offline demo has no live model. Use the question box or select a numbered point.','离线模式未连接实时模型，请输入问题或选择编号点位。'));inputRef.current?.focus();return;}
    try{
      if(!liveRef.current?.ready)await ensureLive(analysisRef.current);
      if(!liveRef.current?.ready)throw new Error(cn(languageRef.current,'Live voice is unavailable. You can still type questions.','实时语音不可用，仍可输入问题。'));
      await liveRef.current.startMicrophone();setMicOn(true);setNotice(cn(languageRef.current,'Listening through your computer microphone. Use headphones to reduce echo.','正在使用电脑麦克风，建议佩戴耳机以减少回声。'));
    }catch(e){setError(e instanceof Error?e.message:String(e));}
  };

  const loadFile=async(file:File)=>{
    reset();cleanupInput();++inputGeneration.current;setMotion(false);setCameraStatus('idle');
    if(file.type.startsWith('video/')){
      const video=document.createElement('video');video.src=URL.createObjectURL(file);video.loop=true;video.muted=true;video.playsInline=true;videoRef.current=video;
      try{await video.play();setInputKind('video');}catch{setError(cn(languageRef.current,'Could not play this video. Try an MP4 file.','无法播放该视频，请尝试 MP4。'));}
    }else if(file.type.startsWith('image/')){setInputKind('image');setImageUrl(URL.createObjectURL(file));}
  };
  const useCamera=async()=>{
    reset();cleanupInput();setMotion(false);setInputKind('camera');setImageUrl('');setCameraStatus('requesting');
    const generation=inputGeneration.current;
    try{
      const {stream,video}=await openBrowserVideo(navigator.mediaDevices);
      if(generation!==inputGeneration.current){stream.getTracks().forEach(track=>track.stop());video.pause();video.srcObject=null;return false;}
      cameraRef.current=stream;videoRef.current=video;setCameraStatus('ready');setSettingsOpen(false);
      stream.getTracks().forEach(track=>track.addEventListener('ended',()=>{if(generation!==inputGeneration.current)return;cleanupInput();interrupt();setCameraStatus('unavailable');setNotice(cn(languageRef.current,'Camera disconnected. Reconnect before scanning.','相机已断开，请重新连接后识别。'));}));
      return true;
    }catch(e){
      if(generation!==inputGeneration.current)return false;
      const reason=cameraFailure(e);setCameraStatus(reason);
      setError(reason==='unsupported'?cn(languageRef.current,'This Web App cannot access the glasses camera. A paired-phone DAT app is required to connect its video stream.','此眼镜网页无法读取眼镜相机，需要通过配对手机上的 DAT 应用接入视频流。'):reason==='denied'?cn(languageRef.current,'Camera permission was denied. Allow camera access, then scan again.','相机权限未获允许，请授权后重新扫描。'):cn(languageRef.current,'No live video frame was received. Reconnect the camera and try again.','尚未收到实时视频帧，请重新连接相机后重试。'));
      return false;
    }
  };
  const useIncludedArtwork=()=>{reset();cleanupInput();setCameraStatus('idle');setInputKind('image');setImageUrl('/artworks/wheat-field.jpg');};

  useEffect(()=>{
    const handler=(event:KeyboardEvent)=>{
      if((event.target as HTMLElement)?.matches('input,textarea,select'))return;
      const data=analysisRef.current;if(!data || settingsOpen || sourcesOpen || languageChanging)return;
      const listVisible=!['ready','error','overview','analyzing'].includes(phaseRef.current);
      if(listVisible && (event.key==='ArrowDown'||event.key==='ArrowUp')){
        event.preventDefault();event.stopPropagation();
        const next=(focusIndex+(event.key==='ArrowDown'?1:-1)+data.details.length)%data.details.length;
        setFocusIndex(next);detailButtonRefs.current[next]?.focus({preventScroll:true});
        detailButtonRefs.current[next]?.scrollIntoView({block:'nearest',inline:'nearest'});return;
      }
      if(event.key==='Enter' && (event.target as HTMLElement)?.closest('button') && !(event.target as HTMLElement)?.closest('.detail-item'))return;
      if(listVisible && event.key==='Enter' && data.details[focusIndex]){event.preventDefault();event.stopPropagation();selectRef.current(data.details[focusIndex],false);return;}
      if(event.key==='Escape'){event.preventDefault();interrupt();setSourcesOpen(false);}
      if(listVisible && /^[1-9]$/.test(event.key)){const d=data.details.find(p=>p.number===Number(event.key));if(d){event.preventDefault();event.stopPropagation();selectRef.current(d,false);}}
    };
    window.addEventListener('keydown',handler,true);return()=>window.removeEventListener('keydown',handler,true);
  },[focusIndex,interrupt,settingsOpen,sourcesOpen,languageChanging]);
  const selected=analysis?.details.find(d=>d.id===selectedId);
  const active=!!analysis && phase!=='ready'&&phase!=='error';
  const showList=active&&phase!=='overview'&&phase!=='analyzing';
  const currentIndex=analysis?.details.findIndex(d=>d.id===selectedId)??-1;
  const box=poly?bounds(poly):null;

  return <WearableApp><main className={`museum-app ${overlayOnly?'overlay-mode':''} ${active?'visit-active':'visit-lobby'}`}>
    <div className="perspective" ref={stageRef}>
      <canvas ref={sceneRef} width={W} height={W} className={`scene-canvas ${overlayOnly?'scene-hidden':''}`} aria-label={cn(language,'Artwork input preview','作品输入预览')}/>
      <div className="scene-vignette"/>
      <header className="topbar">
        <button className="wordmark" onClick={()=>active?setSettingsOpen(!settingsOpen):undefined} aria-label={strings.settings}><span className="brand-symbol">◈</span><span>MUSE<span className="wordmark-dot">.</span></span></button>
        <div className="top-status"><span className={`status-light ${config?.configured?'online':''}`}/>{analysis ? (demo?'OFFLINE DEMO':'GEMINI') : cn(language,'A PERSONAL ART COMPANION','你的随身艺术导览')}</div>
        <button className="icon-button settings-button" title={strings.settings} onClick={()=>setSettingsOpen(!settingsOpen)} aria-label={strings.settings}>⚙</button>
      </header>

      {!active&&<section className="welcome-panel">
        <div className="eyebrow">THE ART OF NOTICING</div>
        <h1>{strings.title}</h1>
        <p className="welcome-subtitle">{strings.subtitle}</p>
        <div className="artwork-caption"><span className="fine-line"/><span>{imageUrl==='/artworks/wheat-field.jpg' && inputKind==='image' ? <>Vincent van Gogh<br/><strong>Wheat Field with Cypresses</strong><small>1889 · The Metropolitan Museum of Art</small></> : <><strong>{inputKind==='camera'?cameraStatus==='ready'?cn(language,'Live camera connected','实时相机已连接'):cn(language,'Aim at an artwork','请对准眼前的作品'):inputKind==='video'?cn(language,'Your uploaded video','你上传的视频'):cn(language,'Your uploaded artwork','你上传的作品')}</strong><small>{inputKind==='camera'&&cameraStatus==='unsupported'?cn(language,'Waiting for the paired-phone camera connection.','等待配对手机接入眼镜视频流。'):cn(language,'Live frames are required before recognition begins.','收到真实画面后，开始识别与讲解。')}</small></>}</span></div>
        <div className="start-actions">
          <WearableButton title={cameraStatus==='requesting'?cn(language,'Connecting camera…','正在连接相机…'):phase==='analyzing'?strings.analyzing:inputKind==='camera'?cn(language,'Scan the artwork','识别眼前作品'):strings.start} onClick={()=>void startTour(false)} disabled={phase==='analyzing'||cameraStatus==='requesting'||(!imageReady&&inputKind==='image')}/>
          {inputKind==='camera'?<button className="demo-link" onClick={useIncludedArtwork}>{cn(language,'Choose the demo artwork','手动选择演示画作')}<span>↗</span></button>:<button className="demo-link" onClick={()=>void startTour(true)} disabled={phase==='analyzing'||inputKind!=='image'||imageUrl!=='/artworks/wheat-field.jpg'}>{strings.demo}<span>↗</span></button>}
        </div>
        <div className="connection-note"><span className={`status-light ${config?.configured?'online':''}`}/>{config?.configured?strings.keyReady:strings.noKey}{!config?.configured&&<span className="hint"> · .env.local</span>}</div>
      </section>}

      {active&&<>
        <div className="visit-artwork"><span className="eyebrow">{analysis.artwork.artist} · {analysis.artwork.year}</span><h2>{analysis.artwork.title}</h2></div>
        {poly&&showList&&<svg className="tracking-overlay" viewBox={`0 0 ${W} ${W}`} preserveAspectRatio="xMidYMid slice" aria-label={cn(language,'Tracked detail outline','细节点追踪框')}><polygon points={poly.map(p=>p.join(',')).join(' ')} fill="none" stroke="currentColor" strokeWidth="2.5" vectorEffect="non-scaling-stroke"/>{box&&<g><rect x={Math.max(0,box.x)} y={Math.max(0,box.y-30)} width="30" height="27" rx="6"/><text x={Math.max(0,box.x)+15} y={Math.max(0,box.y-30)+19} textAnchor="middle">{selected?.number}</text></g>}</svg>}
        {showList&&<aside className={`detail-sidebar ${zoom>1?'with-zoom':''}`}>
          {zoom>1&&<div className="zoom-panel"><canvas ref={zoomRef} width="320" height="320"/><span className="zoom-tag">{zoom}×</span>{!poly&&<span className="zoom-unavailable">{strings.lost}</span>}</div>}
          <div className="detail-panel"><div className="panel-heading"><span>{strings.points}</span><span>{analysis.details.length.toString().padStart(2,'0')}</span></div>
            <div className="detail-items" role="listbox" aria-label={strings.points}>
              {analysis.details.map((detail,i)=><button key={detail.id} ref={element=>{detailButtonRefs.current[i]=element;}} tabIndex={focusIndex===i?0:-1} disabled={languageChanging} role="option" aria-selected={selectedId===detail.id} className={`detail-item ${selectedId===detail.id?'selected':''} ${focusIndex===i?'nav-focus':''}`} onFocus={()=>setFocusIndex(i)} onClick={()=>selectRef.current(detail,false)}>
                <span className="detail-number">{detail.number.toString().padStart(2,'0')}</span><span className="detail-name">{detail.title}</span><span className="detail-mark">{selectedId===detail.id?'◉':seen.includes(detail.id)?'✓':'↗'}</span>
              </button>)}
            </div>
          </div>
        </aside>}
        {showList&&!poly&&<div className="tracking-notice"><span className="pulse-dot"/>{tracking==='loading'?cn(language,'Preparing visual tracker…','正在准备视觉追踪…'):strings.lost}</div>}
        <section className={`narration-panel ${showList?'narrow':''}`} aria-live="polite">
          <div className="narration-heading"><span className={`audio-bars ${speaking?'playing':''}`}><i/><i/><i/><i/></span><span>{phase==='overview'?strings.overview:phase==='answering'?strings.ask:phase==='paused'?cn(language,'PAUSED · YOUR TURN','已暂停 · 请提问'):strings.now}</span>{selected&&<span className="current-point">{selected.number.toString().padStart(2,'0')}</span>}<label className="speed-control"><span>{cn(language,'Speed','倍速')}</span><select aria-label={cn(language,'Narration playback speed','语音播放倍速')} value={playbackRate} onChange={event=>changePlaybackSpeed(Number(event.target.value))}>{PLAYBACK_RATES.map(rate=><option key={rate} value={rate}>{rate}×</option>)}</select></label></div>
          {selected&&showList&&<h3>{selected.title}</h3>}
          <p className="narration-copy">{caption||analysis.overview}</p>
          <div className="narration-controls">
            {phase==='overview'?<button className="text-button" onClick={()=>{interrupt();selectRef.current(analysis.details[0],true);}}>{strings.skip}<span>→</span></button>:<><button className="transport-button" disabled={languageChanging} aria-label={speaking?strings.pause:strings.resume} onClick={()=>speaking?interrupt():resume()}>{speaking?'Ⅱ':'▶'}</button><button className="text-button" disabled={languageChanging} onClick={next}>{strings.next}<span>→</span></button></>}
            <button className="source-button" onClick={()=>setSourcesOpen(!sourcesOpen)} aria-label={strings.sources}>ⓘ</button>
          </div>
        </section>
        <div className="visit-footer"><span className="tracking-state"><span className={`status-light ${poly?'online':''}`}/>{motion?cn(language,'SIMULATED MOTION','合成移动'):inputKind==='image'?cn(language,'REFERENCE IMAGE','参考图片'):poly?strings.track:strings.lost}</span><div className="zoom-controls" aria-label="Zoom">{[1,2,4].map(value=><button key={value} className={zoom===value?'chosen':''} onClick={()=>setZoom(value)}>{value}×</button>)}</div></div>
      </>}

      {(phase==='analyzing')&&<div className="loading-panel"><span className="loading-orbit"/><p>{strings.analyzing}</p><small>{demo?cn(language,'Loading explicitly labeled demo content','正在载入离线演示内容'):cn(language,'Gemini is finding the stories in your frame','Gemini 正在识别画面中的细节点')}</small><button onClick={reset} className="text-button">{cn(language,'Cancel','取消')}</button></div>}
      {sourcesOpen&&analysis&&<section className="sources-panel"><div className="panel-heading"><span>{strings.sources}</span><button className="close-button" onClick={()=>setSourcesOpen(false)} aria-label="Close">×</button></div><p>{cn(language,'Historical context is grounded in these collection records. Visual observations may be AI-generated.','历史背景依据以下馆藏资料。画面观察可能由 AI 生成。')}</p>{analysis.sources.map(source=><a key={source.id} href={source.url} target="_blank" rel="noreferrer">{source.title}<span>↗</span></a>)}</section>}
      {settingsOpen&&<section className="settings-panel"><div className="panel-heading"><span>{strings.settings}</span><button className="close-button" onClick={()=>setSettingsOpen(false)} aria-label="Close">×</button></div>
        <label className="field-label">{cn(language,'LANGUAGE','语言')}</label><div className="segmented"><button className={language==='en'?'chosen':''} onClick={()=>changeLanguage('en')}>English</button><button className={language==='zh'?'chosen':''} onClick={()=>changeLanguage('zh')}>中文</button></div>
        <label className="field-label" htmlFor="settings-playback-speed">{cn(language,'NARRATION SPEED','语音播放倍速')}</label><select id="settings-playback-speed" className="settings-speed" value={playbackRate} onChange={event=>changePlaybackSpeed(Number(event.target.value))}>{PLAYBACK_RATES.map(rate=><option key={rate} value={rate}>{rate}×</option>)}</select><small className="speed-hint">{cn(language,'Say “set playback speed to 1.5”, “speak slower”, or “normal speed”.','可说「调到一点五倍速」「慢一点」「恢复正常语速」。')}</small>
        <label className="field-label">{strings.input}</label><div className="input-actions"><button onClick={()=>uploadRef.current?.click()}>↑ {strings.upload}</button><button onClick={()=>void useCamera()}>◉ {strings.camera}</button></div>
        <button className="text-button" onClick={useIncludedArtwork}>{cn(language,'Use the included Van Gogh artwork','使用内置梵高作品')}<span>↗</span></button>
        <label className="toggle-row"><span>{strings.motion}<small>{cn(language,'Synthetic motion for the reference image','仅对参考图进行合成移动')}</small></span><input type="checkbox" checked={motion} disabled={inputKind!=='image'} onChange={e=>setMotion(e.target.checked)}/></label>
        <label className="toggle-row"><span>{strings.overlay}<small>{cn(language,'Use your simulator environment background','使用模拟器自己的环境背景')}</small></span><input type="checkbox" checked={overlayOnly} onChange={e=>setOverlayOnly(e.target.checked)}/></label>
        <div className="config-state"><span className={`status-light ${config?.configured?'online':''}`}/>{config?.configured?strings.keyReady:strings.noKey}<small>{config?.model||'Gemini'} · {cn(language,'Key stays on your local server','密钥只保留在本地后端')}</small></div>
        {active&&<button className="end-button" onClick={reset}>{strings.stop}</button>}
      </section>}
      {error&&<div className="error-banner" role="alert"><span>{error}</span><button onClick={()=>setError('')} aria-label="Dismiss">×</button></div>}
      {notice&&<div className="notice-banner" role="status"><span>{notice}</span><button onClick={()=>setNotice('')} aria-label="Dismiss">×</button></div>}
      {!active&&<footer className="lobby-footer"><span>ONE ARTWORK. ENDLESS DISCOVERIES.</span><div className="language-switch"><button className={language==='en'?'active':''} onClick={()=>changeLanguage('en')}>EN</button><span>/</span><button className={language==='zh'?'active':''} onClick={()=>changeLanguage('zh')}>中</button></div></footer>}
    </div>
    {active&&<form className="question-bar" onSubmit={e=>{e.preventDefault();void askQuestion(question);}}><button type="button" className={`mic-button ${micOn?'listening':''}`} onClick={()=>void toggleMic()} aria-label={strings.mic} title={strings.mic}>{micOn?'■':'♩'}</button><input ref={inputRef} value={question} onChange={e=>setQuestion(e.target.value)} onFocus={interrupt} placeholder={cn(language,'Ask anything, or “tell me about point 3”…','随时提问，或说「讲第 3 个」…')} aria-label={strings.ask}/><button type="submit" className="send-button" disabled={!question.trim()} aria-label="Send question">↑</button></form>}
    <input ref={uploadRef} type="file" accept="image/*,video/*" hidden onChange={e=>{const file=e.target.files?.[0];if(file)void loadFile(file);e.target.value='';}}/>
    <div className="runtime-note">{active?`${voiceMode==='live'?strings.live:strings.muted} · `:''}{cn(language,'Simulator prototype · optical alignment requires real glasses','模拟器原型 · 真实镜片对齐待真机验证')}</div>
  </main></WearableApp>;
}
