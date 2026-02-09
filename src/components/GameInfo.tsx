'use client';

import React from 'react';
import { getStatusMessage } from '../utils/chess';
import type { GameStatus, ChessMove } from '../types/chess';

interface GameInfoProps {
  status: GameStatus;
  isWhiteTurn: boolean;
  moveCount: number;
  isInCheck: boolean;
  moves: ChessMove[];
}

export function GameInfo({
  status,
  isWhiteTurn,
  moveCount,
  isInCheck,
  moves,
}: GameInfoProps) {
  const statusMessage = getStatusMessage(status, isWhiteTurn);
  const isGameOver = status !== 'active';

  // Get last few moves for display
  const recentMoves = moves.slice(-6);

  return (
    <div className="bg-gray-800/50 rounded-xl p-4 space-y-4 border border-gray-700/50">
      {/* Turn Indicator */}
      <div className="flex items-center justify-between">
        <span className="text-gray-400 text-sm">Turn</span>
        <div className="flex items-center gap-2">
          <div
            className={`w-4 h-4 rounded-full ${
              isWhiteTurn ? 'bg-white' : 'bg-gray-900 border border-gray-600'
            }`}
          />
          <span className="text-white font-medium">
            {isWhiteTurn ? 'White (You)' : 'Black (AI)'}
          </span>
        </div>
      </div>

      {/* Status */}
      <div className="flex items-center justify-between">
        <span className="text-gray-400 text-sm">Status</span>
        <span
          className={`font-medium ${
            isGameOver
              ? status === 'white_win'
                ? 'text-green-400'
                : status === 'black_win'
                ? 'text-red-400'
                : 'text-yellow-400'
              : isInCheck
              ? 'text-red-400'
              : 'text-white'
          }`}
        >
          {isInCheck && status === 'active' ? 'Check!' : statusMessage}
        </span>
      </div>

      {/* Move Count */}
      <div className="flex items-center justify-between">
        <span className="text-gray-400 text-sm">Moves</span>
        <span className="text-white font-mono">{Math.floor(moveCount / 2) + 1}</span>
      </div>

      {/* Recent Moves */}
      {recentMoves.length > 0 && (
        <div className="border-t border-gray-700/50 pt-3">
          <span className="text-gray-400 text-sm block mb-2">Recent Moves</span>
          <div className="space-y-1 text-xs font-mono">
            {recentMoves.map((move, idx) => {
              const moveNum = moves.length - recentMoves.length + idx;
              const isWhiteMove = moveNum % 2 === 0;
              const fromFile = String.fromCharCode(97 + (move.from_square % 8));
              const fromRank = Math.floor(move.from_square / 8) + 1;
              const toFile = String.fromCharCode(97 + (move.to_square % 8));
              const toRank = Math.floor(move.to_square / 8) + 1;

              return (
                <div
                  key={idx}
                  className={`flex justify-between ${
                    isWhiteMove ? 'text-gray-200' : 'text-gray-400'
                  }`}
                >
                  <span>{isWhiteMove ? `${Math.floor(moveNum / 2) + 1}.` : '...'}</span>
                  <span>
                    {fromFile}{fromRank} → {toFile}{toRank}
                    {move.captured_piece > 0 && ' x'}
                    {move.is_castling && ' O-O'}
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

export default GameInfo;
