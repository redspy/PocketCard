import React, { lazy, Suspense } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import Board from './play/Board.tsx';
import DebugPhone from './play/DebugPhone.tsx';
import './styles.css';

// 경로: /  → 웹 게임판(로비·게임판, 실제 서버 연결)
//       /demo → 데모 플레이 (서버·폰 없이 브라우저 안에서 진행)
//       /dev/phone?p=1|2 → 웹 디버그 폰
//       /dev/setup → 이전 셋업 테스트 화면 (개발용)
const Demo = lazy(() => import('./play/Demo.tsx'));
const path = location.pathname.replace(/\/+$/, '') || '/';
const Page = path === '/demo' ? Demo : path === '/dev/phone' ? DebugPhone : path === '/dev/setup' ? App : Board;

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Suspense fallback={null}>
      <Page />
    </Suspense>
  </React.StrictMode>,
);
