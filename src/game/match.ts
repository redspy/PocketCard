// 한 판의 공용 코어 — 서버(server/session.ts)와 브라우저 데모(src/play/localHost.ts)가 같이 쓴다.
//  상태 + 입력 로그, 자리별 입력 검증, 시점별 메시지(events → state 순서) 생성, 로그 리플레이.
//  Node·DOM 의존 없음 (tests/game/imports.test.ts 가 검사).
import { applyInput, createGame } from './engine.ts';
import type { CardInfo } from './types.ts';
import { toGameInput } from './protocol.ts';
import type { ClientInput, ServerMsg } from './protocol.ts';
import type { GameConfig, GameEvent, GameInput, GameState, Seat, Viewer } from './types.ts';
import { GameError } from './types.ts';
import { eventsFor, viewFor } from './view.ts';

/** 엔진 동작이 바뀌어 옛 로그를 그대로 재생할 수 없게 되면 올린다 */
export const ENGINE_VERSION = '2';

/** 시드 + 입력 로그 (서버 저장 파일의 game 부분, 데모 내보내기 형식) */
export type MatchLog = { v: 1; engine: string; config: GameConfig; inputs: GameInput[] };

export class ReplayError extends Error {
  index: number;
  constructor(index: number, message: string) {
    super(`입력 ${index + 1}번째에서 재생 실패: ${message}`);
    this.index = index;
  }
}

export type SubmitResult = { ok: true; events: GameEvent[] } | { ok: false; error: { code: string; message: string } };

export class Match {
  config: GameConfig;
  inputs: GameInput[] = [];
  state: GameState;
  info: CardInfo;
  /** 마지막으로 처리한 입력의 이벤트 (시작 직후에는 셋업 시작 이벤트) */
  lastEvents: GameEvent[];

  constructor(config: GameConfig, info: CardInfo) {
    this.config = config;
    this.info = info;
    const { state, events } = createGame(config, info);
    this.state = state;
    this.lastEvents = events;
  }

  /** 로그를 처음부터(또는 upTo 개까지) 재생 */
  static replay(log: Pick<MatchLog, 'config' | 'inputs'>, info: CardInfo, upTo = log.inputs.length): Match {
    const m = new Match(log.config, info);
    for (let i = 0; i < upTo; i++) {
      try {
        const r = applyInput(m.state, log.inputs[i], info);
        m.state = r.state;
        m.lastEvents = r.events;
        m.inputs.push(log.inputs[i]);
      } catch (e) {
        throw new ReplayError(i, (e as Error).message);
      }
    }
    return m;
  }

  get log(): MatchLog { return { v: 1, engine: ENGINE_VERSION, config: this.config, inputs: [...this.inputs] }; }

  /** 자리 seat 의 클라이언트 입력을 처리 (player 는 여기서 채움 — 남의 자리로 입력 불가) */
  submit(seat: Seat, input: ClientInput): SubmitResult {
    let gi: GameInput;
    try { gi = toGameInput(input, seat); } catch { return { ok: false, error: { code: 'bad_input', message: '입력 형식 오류' } }; }
    return this.apply(gi);
  }

  /** 이미 player 가 채워진 엔진 입력 (리플레이·봇 내부용) */
  apply(gi: GameInput): SubmitResult {
    try {
      const r = applyInput(this.state, gi, this.info);
      this.state = r.state;
      this.inputs.push(gi);
      this.lastEvents = r.events;
      return { ok: true, events: r.events };
    } catch (e) {
      if (e instanceof GameError) return { ok: false, error: { code: e.code, message: e.message } };
      return { ok: false, error: { code: 'engine_error', message: String((e as Error)?.message ?? e) } };
    }
  }

  /** 접속·재접속용 현재 상태 */
  snapshot(viewer: Viewer): Extract<ServerMsg, { t: 'state' }> {
    return { t: 'state', view: viewFor(this.state, viewer, this.info) };
  }

  /** 입력 처리 결과를 viewer 에게 보낼 메시지 (이벤트 → 상태 순서 고정) */
  messagesFor(viewer: Viewer, events: GameEvent[]): ServerMsg[] {
    const ev = eventsFor(events, viewer);
    return ev.length ? [{ t: 'events', events: ev }, this.snapshot(viewer)] : [this.snapshot(viewer)];
  }
}
