import {
  ChessPiece,
  PieceType,
  PieceColor,
  GameStatus,
  EMPTY, PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING,
  WHITE, BLACK,
  STATUS_ACTIVE, STATUS_WHITE_WIN, STATUS_BLACK_WIN, STATUS_DRAW, STATUS_STALEMATE
} from '../types/chess';

const PIECE_TYPE_MAP: Record<number, PieceType> = {
  [PAWN]: 'pawn',
  [KNIGHT]: 'knight',
  [BISHOP]: 'bishop',
  [ROOK]: 'rook',
  [QUEEN]: 'queen',
  [KING]: 'king',
};

export function decodePiece(code: number): ChessPiece | null {
  const pieceType = code & 7;
  if (pieceType === EMPTY) return null;

  const color: PieceColor = (code & 8) === WHITE ? 'white' : 'black';
  const type = PIECE_TYPE_MAP[pieceType];

  if (!type) return null;

  return { type, color };
}

export function encodePiece(piece: ChessPiece): number {
  const typeMap: Record<PieceType, number> = {
    'pawn': PAWN,
    'knight': KNIGHT,
    'bishop': BISHOP,
    'rook': ROOK,
    'queen': QUEEN,
    'king': KING,
  };

  let code = typeMap[piece.type];
  if (piece.color === 'black') code |= BLACK;
  return code;
}

export function squareToNotation(square: number): string {
  const file = String.fromCharCode(97 + (square % 8)); // a-h
  const rank = Math.floor(square / 8) + 1; // 1-8
  return `${file}${rank}`;
}

export function notationToSquare(notation: string): number {
  const file = notation.charCodeAt(0) - 97; // a=0, h=7
  const rank = parseInt(notation[1]) - 1; // 1=0, 8=7
  return rank * 8 + file;
}

export function getSquareColor(square: number): 'light' | 'dark' {
  const file = square % 8;
  const rank = Math.floor(square / 8);
  return (file + rank) % 2 === 1 ? 'light' : 'dark';
}

export function parseGameStatus(status: number): GameStatus {
  switch (status) {
    case STATUS_ACTIVE: return 'active';
    case STATUS_WHITE_WIN: return 'white_win';
    case STATUS_BLACK_WIN: return 'black_win';
    case STATUS_DRAW: return 'draw';
    case STATUS_STALEMATE: return 'stalemate';
    default: return 'active';
  }
}

export function getStatusMessage(status: GameStatus, isWhiteTurn: boolean): string {
  switch (status) {
    case 'active':
      return isWhiteTurn ? 'Your turn' : 'AI thinking...';
    case 'white_win':
      return 'Checkmate! You win!';
    case 'black_win':
      return 'Checkmate! AI wins.';
    case 'draw':
      return 'Game drawn.';
    case 'stalemate':
      return 'Stalemate! Draw.';
    default:
      return '';
  }
}

export function getPromotionPieces(): { type: PieceType; value: number }[] {
  return [
    { type: 'queen', value: QUEEN },
    { type: 'rook', value: ROOK },
    { type: 'bishop', value: BISHOP },
    { type: 'knight', value: KNIGHT },
  ];
}

export function isPromotionMove(board: number[], from: number, to: number): boolean {
  const piece = board[from];
  const pieceType = piece & 7;
  if (pieceType !== PAWN) return false;

  const toRank = Math.floor(to / 8);
  const isWhite = (piece & 8) === WHITE;

  return (isWhite && toRank === 7) || (!isWhite && toRank === 0);
}

// Format address for display
export function formatAddress(address: string, chars: number = 6): string {
  if (address.length <= chars * 2) return address;
  return `${address.slice(0, chars)}...${address.slice(-chars)}`;
}
