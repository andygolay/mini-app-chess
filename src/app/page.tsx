'use client';

import { useState, useCallback } from 'react';
import { Button } from 'movement-design-system';
import { useMovementSDK } from '@movement-labs/miniapp-sdk';
import { ChessBoard } from '../components/ChessBoard';
import { GameInfo } from '../components/GameInfo';
import { Leaderboard } from '../components/Leaderboard';
import { useChessGame } from '../hooks/useChessGame';
import { decodePiece, isPromotionMove } from '../utils/chess';
import { WHITE } from '../types/chess';

export default function ChessPage() {
  const { sdk, isConnected, address } = useMovementSDK();
  const {
    gameState,
    isLoading,
    error,
    hasGame,
    startNewGame,
    makeMove,
    resign,
    refreshGame,
  } = useChessGame(sdk, address);

  const [selectedSquare, setSelectedSquare] = useState<number | null>(null);
  const [highlightedMoves, setHighlightedMoves] = useState<number[]>([]);
  const [showLeaderboard, setShowLeaderboard] = useState(false);
  const [promotionPending, setPromotionPending] = useState<{
    from: number;
    to: number;
  } | null>(null);

  // Get last move for highlighting
  const lastMove = gameState && gameState.moves.length > 0
    ? {
        from: gameState.moves[gameState.moves.length - 1].from_square,
        to: gameState.moves[gameState.moves.length - 1].to_square,
      }
    : null;

  // Simple client-side move validation for highlighting
  // The actual validation happens on-chain
  const getBasicLegalSquares = useCallback((from: number, board: number[]): number[] => {
    const piece = board[from];
    if (!piece) return [];

    const pieceType = piece & 7;
    const isWhite = (piece & 8) === WHITE;

    // Only allow moves for white pieces on player's turn
    if (!isWhite) return [];

    const legalSquares: number[] = [];
    const fromRow = Math.floor(from / 8);
    const fromCol = from % 8;

    // Add all potential target squares based on piece type
    // This is simplified - the contract does full validation
    for (let to = 0; to < 64; to++) {
      if (to === from) continue;

      const target = board[to];
      const targetType = target & 7;
      const targetIsWhite = (target & 8) === WHITE;

      // Can't capture own pieces
      if (targetType !== 0 && targetIsWhite) continue;

      const toRow = Math.floor(to / 8);
      const toCol = to % 8;
      const rowDiff = Math.abs(toRow - fromRow);
      const colDiff = Math.abs(toCol - fromCol);

      let isValid = false;

      switch (pieceType) {
        case 1: // Pawn
          if (isWhite) {
            // Forward move
            if (toCol === fromCol && targetType === 0) {
              if (toRow === fromRow + 1) isValid = true;
              if (fromRow === 1 && toRow === 3 && board[from + 8] === 0) isValid = true;
            }
            // Capture
            if (toRow === fromRow + 1 && colDiff === 1 && targetType !== 0) {
              isValid = true;
            }
          }
          break;
        case 2: // Knight
          if ((rowDiff === 2 && colDiff === 1) || (rowDiff === 1 && colDiff === 2)) {
            isValid = true;
          }
          break;
        case 3: // Bishop
          if (rowDiff === colDiff && rowDiff > 0) isValid = true;
          break;
        case 4: // Rook
          if ((rowDiff === 0 || colDiff === 0) && (rowDiff + colDiff > 0)) isValid = true;
          break;
        case 5: // Queen
          if (rowDiff === colDiff || rowDiff === 0 || colDiff === 0) {
            if (rowDiff + colDiff > 0) isValid = true;
          }
          break;
        case 6: // King
          if (rowDiff <= 1 && colDiff <= 1 && (rowDiff + colDiff > 0)) isValid = true;
          // Castling
          if (rowDiff === 0 && colDiff === 2) isValid = true;
          break;
      }

      if (isValid) {
        legalSquares.push(to);
      }
    }

    return legalSquares;
  }, []);

  const handleSquareClick = useCallback(
    async (square: number) => {
      if (!gameState) return;
      if (gameState.status !== 'active') return;
      if (!gameState.isWhiteTurn) return;

      const board = gameState.board;

      if (selectedSquare === null) {
        // Selecting a piece
        const piece = board[square];
        if (!piece) return;

        const pieceColor = piece & 8;
        if (pieceColor !== WHITE) return; // Can only select white pieces

        setSelectedSquare(square);
        const moves = getBasicLegalSquares(square, board);
        setHighlightedMoves(moves);
      } else {
        // Attempting to move
        if (highlightedMoves.includes(square)) {
          // Check if this is a pawn promotion
          if (isPromotionMove(board, selectedSquare, square)) {
            setPromotionPending({ from: selectedSquare, to: square });
          } else {
            await makeMove(selectedSquare, square, 0);
          }
        }

        // Clear selection regardless
        setSelectedSquare(null);
        setHighlightedMoves([]);
      }
    },
    [gameState, selectedSquare, highlightedMoves, makeMove, getBasicLegalSquares]
  );

  const handlePromotion = useCallback(
    async (pieceType: number) => {
      if (!promotionPending) return;

      await makeMove(promotionPending.from, promotionPending.to, pieceType);
      setPromotionPending(null);
      setSelectedSquare(null);
      setHighlightedMoves([]);
    },
    [promotionPending, makeMove]
  );

  const isGameActive = gameState?.status === 'active';
  const isPlayerTurn = gameState?.isWhiteTurn ?? true;
  const canPlay = isConnected && isGameActive && isPlayerTurn && !isLoading;

  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-900 via-gray-800 to-gray-900 p-4">
      <div className="max-w-5xl mx-auto">
        {/* Header */}
        <div className="text-center mb-6">
          <h1 className="text-3xl font-bold text-white mb-2">Chess on Movement</h1>
          <p className="text-gray-400">
            Play against the AI - all moves verified on-chain
          </p>
        </div>

        {/* Main content */}
        <div className="grid lg:grid-cols-3 gap-6">
          {/* Chess board */}
          <div className="lg:col-span-2">
            {!isConnected ? (
              <div className="aspect-square bg-gray-800/50 rounded-xl flex items-center justify-center border border-gray-700/50">
                <div className="text-center">
                  <p className="text-gray-400 mb-4">Connect your wallet to play</p>
                </div>
              </div>
            ) : !hasGame ? (
              <div className="aspect-square bg-gray-800/50 rounded-xl flex items-center justify-center border border-gray-700/50">
                <div className="text-center">
                  <p className="text-gray-400 mb-4">No active game</p>
                  <Button
                    onClick={startNewGame}
                    disabled={isLoading}
                    variant="default"
                    color="green"
                    size="lg"
                  >
                    {isLoading ? 'Starting...' : 'Start New Game'}
                  </Button>
                </div>
              </div>
            ) : gameState ? (
              <ChessBoard
                board={gameState.board}
                selectedSquare={selectedSquare}
                highlightedMoves={highlightedMoves}
                lastMove={lastMove}
                whiteKingPos={gameState.whiteKingPos}
                blackKingPos={gameState.blackKingPos}
                isInCheck={gameState.isInCheck}
                isWhiteTurn={gameState.isWhiteTurn}
                disabled={!canPlay}
                onSquareClick={handleSquareClick}
                promotionPending={promotionPending}
                onPromotion={handlePromotion}
              />
            ) : null}

            {/* Game controls */}
            {isConnected && (
              <div className="mt-4 flex flex-wrap gap-3 justify-center">
                <Button
                  onClick={startNewGame}
                  disabled={isLoading}
                  variant="default"
                  color="green"
                >
                  {isLoading ? 'Loading...' : 'New Game'}
                </Button>

                {hasGame && isGameActive && (
                  <Button
                    onClick={resign}
                    disabled={isLoading}
                    variant="outline"
                  >
                    Resign
                  </Button>
                )}

                <Button
                  onClick={() => setShowLeaderboard(!showLeaderboard)}
                  variant="outline"
                >
                  {showLeaderboard ? 'Hide Leaderboard' : 'Leaderboard'}
                </Button>

                <Button
                  onClick={refreshGame}
                  disabled={isLoading}
                  variant="outline"
                >
                  Refresh
                </Button>
              </div>
            )}

            {/* Error display */}
            {error && (
              <div className="mt-4 p-3 bg-red-900/50 border border-red-500/50 rounded-lg text-red-200 text-sm text-center">
                {error}
              </div>
            )}
          </div>

          {/* Side panel */}
          <div className="space-y-4">
            {gameState && (
              <GameInfo
                status={gameState.status}
                isWhiteTurn={gameState.isWhiteTurn}
                moveCount={gameState.moveCount}
                isInCheck={gameState.isInCheck}
                moves={gameState.moves}
              />
            )}

            {showLeaderboard && <Leaderboard sdk={sdk} address={address} />}

            {/* How to play */}
            {!showLeaderboard && (
              <div className="bg-gray-800/50 rounded-xl p-4 border border-gray-700/50">
                <h3 className="text-lg font-semibold text-white mb-3">How to Play</h3>
                <ul className="text-gray-400 text-sm space-y-2">
                  <li>• You play as White (bottom)</li>
                  <li>• Click a piece to select, click destination to move</li>
                  <li>• Green dots show legal moves</li>
                  <li>• AI responds automatically after your move</li>
                  <li>• Win to earn points for the leaderboard!</li>
                </ul>
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        {address && (
          <div className="mt-6 text-center text-xs text-gray-500 font-mono">
            Connected: {address.slice(0, 8)}...{address.slice(-6)}
          </div>
        )}
      </div>
    </div>
  );
}
