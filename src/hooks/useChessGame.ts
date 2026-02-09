'use client';

import { useState, useEffect, useCallback } from 'react';
import { CHESS_MODULE_ADDRESS } from '../../constants';
import { parseGameStatus, squareToNotation } from '../utils/chess';
import type { GameState, ChessMove, GameStatus } from '../types/chess';

interface UseChessGameResult {
  gameState: GameState | null;
  isLoading: boolean;
  error: string;
  hasGame: boolean;
  startNewGame: () => Promise<void>;
  makeMove: (from: number, to: number, promotion: number) => Promise<void>;
  resign: () => Promise<void>;
  claimDraw: () => Promise<void>;
  refreshGame: () => Promise<void>;
}

export function useChessGame(
  sdk: any,
  address: string | null
): UseChessGameResult {
  const [gameState, setGameState] = useState<GameState | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [hasGame, setHasGame] = useState(false);

  // Fetch current game state
  const refreshGame = useCallback(async () => {
    if (!sdk || !address) return;

    try {
      // Check if player has a game
      const hasGameResult = await sdk.view({
        function: `${CHESS_MODULE_ADDRESS}::chess::has_game`,
        type_arguments: [],
        function_arguments: [address],
      });

      const gameExists = Array.isArray(hasGameResult) ? hasGameResult[0] : hasGameResult;
      setHasGame(Boolean(gameExists));

      if (!gameExists) {
        setGameState(null);
        return;
      }

      // Get game state
      const gameResult = await sdk.view({
        function: `${CHESS_MODULE_ADDRESS}::chess::get_game`,
        type_arguments: [],
        function_arguments: [address],
      });

      // Handle different response formats
      let boardData: any = [];
      let isWhiteTurn = true;
      let status = 0;
      let moveCount = 0;
      let whiteKingPos = 4;
      let blackKingPos = 60;

      if (Array.isArray(gameResult)) {
        [boardData, isWhiteTurn, status, moveCount, whiteKingPos, blackKingPos] = gameResult;
      } else if (gameResult && typeof gameResult === 'object') {
        const r = gameResult as any;
        boardData = r[0] || r.board || [];
        isWhiteTurn = r[1] ?? r.is_white_turn ?? true;
        status = r[2] ?? r.status ?? 0;
        moveCount = r[3] ?? r.move_count ?? 0;
        whiteKingPos = r[4] ?? r.white_king_pos ?? 4;
        blackKingPos = r[5] ?? r.black_king_pos ?? 60;
      }

      // Parse board data - handle various formats
      let board: number[] = [];

      if (typeof boardData === 'string' && boardData.startsWith('0x')) {
        // Board is a hex string - parse each byte
        const hexStr = boardData.slice(2); // Remove '0x' prefix
        for (let i = 0; i < hexStr.length; i += 2) {
          const byte = parseInt(hexStr.slice(i, i + 2), 16);
          board.push(byte);
        }
      } else if (Array.isArray(boardData)) {
        board = boardData.map((b: any) => Number(b));
      } else if (boardData && typeof boardData === 'object') {
        // Convert object with numeric keys to array
        const keys = Object.keys(boardData).filter(k => !isNaN(Number(k))).sort((a, b) => Number(a) - Number(b));
        board = keys.map(k => Number((boardData as any)[k]));
      }

      // Ensure board has 64 squares
      if (board.length !== 64) {
        console.warn('[Chess] Invalid board length:', board.length);
        board = new Array(64).fill(0);
      }

      // Check if in check
      let isInCheck = false;
      try {
        const checkResult = await sdk.view({
          function: `${CHESS_MODULE_ADDRESS}::chess::is_in_check`,
          type_arguments: [],
          function_arguments: [address],
        });
        isInCheck = Array.isArray(checkResult) ? Boolean(checkResult[0]) : Boolean(checkResult);
      } catch (e) {
        console.warn('[Chess] Failed to check is_in_check:', e);
      }

      // Get move history
      const movesResult = await sdk.view({
        function: `${CHESS_MODULE_ADDRESS}::chess::get_moves`,
        type_arguments: [],
        function_arguments: [address],
      });

      let movesData: any[] = [];
      if (Array.isArray(movesResult)) {
        movesData = movesResult[0] || movesResult || [];
      } else if (movesResult && typeof movesResult === 'object') {
        movesData = (movesResult as any)[0] || [];
      }

      if (!Array.isArray(movesData)) {
        movesData = [];
      }

      const moves: ChessMove[] = movesData.map((m: any) => ({
        from_square: Number(m.from_square ?? m[0] ?? 0),
        to_square: Number(m.to_square ?? m[1] ?? 0),
        promotion: Number(m.promotion ?? m[2] ?? 0),
        captured_piece: Number(m.captured_piece ?? m[3] ?? 0),
        is_castling: Boolean(m.is_castling ?? m[4] ?? false),
        is_en_passant: Boolean(m.is_en_passant ?? m[5] ?? false),
      }));

      setGameState({
        board,
        isWhiteTurn: Boolean(isWhiteTurn),
        status: parseGameStatus(Number(status)),
        moveCount: Number(moveCount),
        whiteKingPos: Number(whiteKingPos),
        blackKingPos: Number(blackKingPos),
        moves,
        isInCheck: Boolean(isInCheck),
      });
    } catch (err) {
      console.error('[Chess] Failed to fetch game:', err);
      setHasGame(false);
      setGameState(null);
    }
  }, [sdk, address]);

  // Start a new game
  const startNewGame = useCallback(async () => {
    if (!sdk || !address) {
      setError('Please connect your wallet first');
      return;
    }

    setIsLoading(true);
    setError('');

    try {
      await sdk.haptic?.({ type: 'impact', style: 'light' });

      const result = await sdk.sendTransaction({
        function: `${CHESS_MODULE_ADDRESS}::chess::new_game`,
        type_arguments: [],
        arguments: [],
        title: 'New Chess Game',
        description: 'Start a new game against the AI',
        useFeePayer: true,
        gasLimit: 'Sponsored',
      });

      console.log('[Chess] New game tx:', result?.hash);
      await refreshGame();

      await sdk.notify?.({
        title: 'Game Started!',
        body: 'You play as white. Good luck!',
      });
    } catch (e) {
      const errorMessage = e instanceof Error ? e.message : 'Failed to start game';
      setError(errorMessage);
    } finally {
      setIsLoading(false);
    }
  }, [sdk, address, refreshGame]);

  // Make a move
  const makeMove = useCallback(
    async (fromSquare: number, toSquare: number, promotion: number) => {
      if (!sdk || !address) {
        setError('Please connect your wallet first');
        return;
      }

      setIsLoading(true);
      setError('');

      try {
        await sdk.haptic?.({ type: 'impact', style: 'medium' });

        const fromNotation = squareToNotation(fromSquare);
        const toNotation = squareToNotation(toSquare);

        const result = await sdk.sendTransaction({
          function: `${CHESS_MODULE_ADDRESS}::chess::make_move`,
          type_arguments: [],
          arguments: [
            fromSquare.toString(),
            toSquare.toString(),
            promotion.toString(),
          ],
          title: 'Chess Move',
          description: `Move ${fromNotation} to ${toNotation}`,
          useFeePayer: true,
          gasLimit: 'Sponsored',
        });

        console.log('[Chess] Move tx:', result?.hash);
        await refreshGame();

        // Check if game ended
        if (gameState) {
          const newStatus = gameState.status;
          if (newStatus === 'white_win') {
            await sdk.notify?.({
              title: 'Victory!',
              body: 'Congratulations, you won!',
            });
            await sdk.haptic?.({ type: 'notification', style: 'success' });
          } else if (newStatus === 'black_win') {
            await sdk.notify?.({
              title: 'Defeat',
              body: 'The AI won this time.',
            });
          }
        }
      } catch (e) {
        const errorMessage = e instanceof Error ? e.message : 'Invalid move';
        setError(errorMessage);
        await sdk.haptic?.({ type: 'notification', style: 'error' });
      } finally {
        setIsLoading(false);
      }
    },
    [sdk, address, refreshGame, gameState]
  );

  // Resign
  const resign = useCallback(async () => {
    if (!sdk || !address) return;

    setIsLoading(true);
    setError('');

    try {
      await sdk.sendTransaction({
        function: `${CHESS_MODULE_ADDRESS}::chess::resign`,
        type_arguments: [],
        arguments: [],
        title: 'Resign',
        description: 'Resign the current game',
        useFeePayer: true,
        gasLimit: 'Sponsored',
      });

      await refreshGame();

      await sdk.notify?.({
        title: 'Game Over',
        body: 'You resigned.',
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to resign');
    } finally {
      setIsLoading(false);
    }
  }, [sdk, address, refreshGame]);

  // Claim draw
  const claimDraw = useCallback(async () => {
    if (!sdk || !address) return;

    setIsLoading(true);
    setError('');

    try {
      await sdk.sendTransaction({
        function: `${CHESS_MODULE_ADDRESS}::chess::claim_draw`,
        type_arguments: [],
        arguments: [],
        title: 'Claim Draw',
        description: 'Claim a draw by 50-move rule or insufficient material',
        useFeePayer: true,
        gasLimit: 'Sponsored',
      });

      await refreshGame();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Cannot claim draw');
    } finally {
      setIsLoading(false);
    }
  }, [sdk, address, refreshGame]);

  // Initial load
  useEffect(() => {
    if (sdk && address) {
      refreshGame();
    }
  }, [sdk, address, refreshGame]);

  return {
    gameState,
    isLoading,
    error,
    hasGame,
    startNewGame,
    makeMove,
    resign,
    claimDraw,
    refreshGame,
  };
}

export default useChessGame;
