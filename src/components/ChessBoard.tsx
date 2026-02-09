'use client';

import React from 'react';
import { ChessPiece } from './ChessPieces';
import { decodePiece, getSquareColor } from '../utils/chess';
import { QUEEN } from '../types/chess';
import type { PieceType } from '../types/chess';

interface ChessBoardProps {
  board: number[];
  selectedSquare: number | null;
  highlightedMoves: number[];
  lastMove: { from: number; to: number } | null;
  whiteKingPos: number;
  blackKingPos: number;
  isInCheck: boolean;
  isWhiteTurn: boolean;
  disabled: boolean;
  onSquareClick: (square: number) => void;
  promotionPending: { from: number; to: number } | null;
  onPromotion: (pieceType: number) => void;
}

const FILES = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
const RANKS = ['8', '7', '6', '5', '4', '3', '2', '1'];

export function ChessBoard({
  board,
  selectedSquare,
  highlightedMoves,
  lastMove,
  whiteKingPos,
  blackKingPos,
  isInCheck,
  isWhiteTurn,
  disabled,
  onSquareClick,
  promotionPending,
  onPromotion,
}: ChessBoardProps) {
  // Render board from white's perspective (rank 8 at top)
  const squares = [];

  for (let displayRow = 0; displayRow < 8; displayRow++) {
    for (let displayCol = 0; displayCol < 8; displayCol++) {
      // Convert display position to square index
      // Display row 0 = rank 8, display row 7 = rank 1
      const rank = 7 - displayRow;
      const file = displayCol;
      const squareIndex = rank * 8 + file;

      const squareColorClass = getSquareColor(squareIndex) === 'light'
        ? 'bg-[#F0D9B5]'
        : 'bg-[#B58863]';

      const isSelected = squareIndex === selectedSquare;
      const isHighlighted = highlightedMoves.includes(squareIndex);
      const isLastMoveSquare = lastMove && (squareIndex === lastMove.from || squareIndex === lastMove.to);

      // Check if this square has the king that's in check
      const kingInCheck = isInCheck && isWhiteTurn && squareIndex === whiteKingPos;

      const piece = board[squareIndex] !== undefined ? decodePiece(board[squareIndex]) : null;
      const hasEnemyPiece = piece && isHighlighted;

      squares.push(
        <div
          key={squareIndex}
          className={`
            relative aspect-square flex items-center justify-center
            ${squareColorClass}
            ${isSelected ? 'ring-4 ring-inset ring-blue-500' : ''}
            ${isLastMoveSquare ? 'bg-yellow-400/40' : ''}
            ${kingInCheck ? 'bg-red-500/50' : ''}
            ${disabled ? 'cursor-default' : 'cursor-pointer hover:brightness-110'}
            transition-all duration-150
          `}
          onClick={() => !disabled && onSquareClick(squareIndex)}
        >
          {/* Piece */}
          {piece && (
            <ChessPiece
              type={piece.type}
              color={piece.color}
              className="w-[85%] h-[85%] drop-shadow-md"
            />
          )}

          {/* Legal move indicator */}
          {isHighlighted && !hasEnemyPiece && (
            <div className="absolute w-[30%] h-[30%] rounded-full bg-green-600/50" />
          )}

          {/* Capture indicator */}
          {isHighlighted && hasEnemyPiece && (
            <div className="absolute inset-0 ring-4 ring-inset ring-green-600/70 rounded-sm" />
          )}

          {/* File label (bottom row) */}
          {displayRow === 7 && (
            <span className={`absolute bottom-0.5 right-1 text-xs font-semibold ${
              getSquareColor(squareIndex) === 'light' ? 'text-[#B58863]' : 'text-[#F0D9B5]'
            }`}>
              {FILES[file]}
            </span>
          )}

          {/* Rank label (left column) */}
          {displayCol === 0 && (
            <span className={`absolute top-0.5 left-1 text-xs font-semibold ${
              getSquareColor(squareIndex) === 'light' ? 'text-[#B58863]' : 'text-[#F0D9B5]'
            }`}>
              {RANKS[displayRow]}
            </span>
          )}
        </div>
      );
    }
  }

  return (
    <div className="relative">
      {/* Board container with shadow */}
      <div className="rounded-lg overflow-hidden shadow-2xl border-4 border-[#5D3A1A]">
        <div className="grid grid-cols-8 aspect-square">
          {squares}
        </div>
      </div>

      {/* Promotion modal */}
      {promotionPending && (
        <PromotionModal
          color="white"
          onSelect={onPromotion}
        />
      )}
    </div>
  );
}

interface PromotionModalProps {
  color: 'white' | 'black';
  onSelect: (pieceType: number) => void;
}

function PromotionModal({ color, onSelect }: PromotionModalProps) {
  const pieces: { type: PieceType; value: number }[] = [
    { type: 'queen', value: 5 },
    { type: 'rook', value: 4 },
    { type: 'bishop', value: 3 },
    { type: 'knight', value: 2 },
  ];

  return (
    <div className="absolute inset-0 bg-black/60 flex items-center justify-center z-10">
      <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-2xl">
        <p className="text-center text-sm font-medium mb-3 text-gray-700 dark:text-gray-200">
          Choose promotion
        </p>
        <div className="flex gap-2">
          {pieces.map(({ type, value }) => (
            <button
              key={type}
              onClick={() => onSelect(value)}
              className="w-16 h-16 bg-[#F0D9B5] hover:bg-[#E0C9A5] rounded-lg flex items-center justify-center transition-colors shadow-md hover:shadow-lg"
            >
              <ChessPiece type={type} color={color} className="w-12 h-12" />
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

export default ChessBoard;
