// Piece types matching contract constants
export const EMPTY = 0;
export const PAWN = 1;
export const KNIGHT = 2;
export const BISHOP = 3;
export const ROOK = 4;
export const QUEEN = 5;
export const KING = 6;

// Colors
export const WHITE = 0;
export const BLACK = 8;

// Game status
export const STATUS_ACTIVE = 0;
export const STATUS_WHITE_WIN = 1;
export const STATUS_BLACK_WIN = 2;
export const STATUS_DRAW = 3;
export const STATUS_STALEMATE = 4;

export type PieceType = 'pawn' | 'knight' | 'bishop' | 'rook' | 'queen' | 'king';
export type PieceColor = 'white' | 'black';

export interface ChessPiece {
  type: PieceType;
  color: PieceColor;
}

export interface ChessMove {
  from_square: number;
  to_square: number;
  promotion: number;
  captured_piece: number;
  is_castling: boolean;
  is_en_passant: boolean;
}

export type GameStatus = 'active' | 'white_win' | 'black_win' | 'draw' | 'stalemate';

export interface PlayerStats {
  wins: number;
  losses: number;
  draws: number;
  totalPoints: number;
  gamesPlayed: number;
}

export interface LeaderboardEntry {
  address: string;
  points: number;
  rank: number;
}

export interface GameState {
  board: number[];
  isWhiteTurn: boolean;
  status: GameStatus;
  moveCount: number;
  whiteKingPos: number;
  blackKingPos: number;
  moves: ChessMove[];
  isInCheck: boolean;
}
