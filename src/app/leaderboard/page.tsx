'use client';

import { useEffect, useState, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from 'movement-design-system';
import { useMovementSDK } from '@movement-labs/miniapp-sdk';
import { CHESS_MODULE_ADDRESS } from '../../../constants';
import { formatAddress } from '../../utils/chess';
import type { PlayerStats, LeaderboardEntry } from '../../types/chess';

export default function LeaderboardPage() {
  const router = useRouter();
  const { sdk, isConnected, address } = useMovementSDK();
  const [entries, setEntries] = useState<LeaderboardEntry[]>([]);
  const [playerStats, setPlayerStats] = useState<PlayerStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const fetchLeaderboard = useCallback(async () => {
    if (!sdk) return;

    try {
      const lbResult = await sdk.view({
        function: `${CHESS_MODULE_ADDRESS}::chess::get_leaderboard`,
        type_arguments: [],
        function_arguments: [],
      });

      const [addresses, points] = Array.isArray(lbResult) ? lbResult : [[], []];

      const leaderboardEntries: LeaderboardEntry[] = (addresses as string[]).map(
        (addr: string, idx: number) => ({
          address: addr,
          points: Number((points as string[])[idx] || 0),
          rank: idx + 1,
        })
      );

      setEntries(leaderboardEntries);

      if (address) {
        const statsResult = await sdk.view({
          function: `${CHESS_MODULE_ADDRESS}::chess::get_player_stats`,
          type_arguments: [],
          function_arguments: [address],
        });

        const [wins, losses, draws, totalPoints, gamesPlayed] = Array.isArray(statsResult)
          ? statsResult
          : [0, 0, 0, 0, 0];

        setPlayerStats({
          wins: Number(wins),
          losses: Number(losses),
          draws: Number(draws),
          totalPoints: Number(totalPoints),
          gamesPlayed: Number(gamesPlayed),
        });
      }
    } catch (err) {
      console.error('[Chess] Failed to fetch leaderboard:', err);
    } finally {
      setIsLoading(false);
    }
  }, [sdk, address]);

  useEffect(() => {
    fetchLeaderboard();
  }, [fetchLeaderboard]);

  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-900 via-gray-800 to-gray-900 p-4">
      <div className="max-w-lg mx-auto">
        {/* Header */}
        <div className="text-center mb-6">
          <h1 className="text-2xl font-bold text-white">Leaderboard</h1>
        </div>

        {/* Leaderboard */}
        <div className="bg-gray-800/50 rounded-xl border border-gray-700/50 overflow-hidden">
          <div className="p-4 border-b border-gray-700/50">
            <h2 className="text-lg font-semibold text-white">Top Players</h2>
          </div>

          {isLoading ? (
            <div className="p-8 text-center text-gray-400">Loading...</div>
          ) : entries.length > 0 ? (
            <div className="divide-y divide-gray-700/50">
              {entries.map((entry) => {
                const isCurrentPlayer = address && entry.address.toLowerCase() === address.toLowerCase();
                return (
                  <div
                    key={entry.address}
                    className={`flex items-center justify-between p-4 ${
                      isCurrentPlayer ? 'bg-blue-900/20' : ''
                    }`}
                  >
                    <div className="flex items-center gap-4">
                      <span
                        className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold ${
                          entry.rank === 1
                            ? 'bg-yellow-500 text-black'
                            : entry.rank === 2
                            ? 'bg-gray-300 text-black'
                            : entry.rank === 3
                            ? 'bg-amber-600 text-white'
                            : 'bg-gray-600 text-gray-200'
                        }`}
                      >
                        {entry.rank}
                      </span>
                      <div>
                        <span className="text-white font-mono text-sm">
                          {formatAddress(entry.address)}
                        </span>
                        {isCurrentPlayer && (
                          <span className="ml-2 text-xs text-blue-400">(You)</span>
                        )}
                      </div>
                    </div>
                    <span className="text-green-400 font-bold text-lg">
                      {entry.points.toLocaleString()}
                    </span>
                  </div>
                );
              })}
            </div>
          ) : (
            <div className="p-8 text-center text-gray-400">
              No games played yet. Be the first!
            </div>
          )}
        </div>

        {/* Player's own stats */}
        {playerStats && playerStats.gamesPlayed > 0 && (
          <div className="mt-6 p-4 bg-green-900/30 rounded-xl border border-green-700/50">
            <div className="text-sm text-green-400 mb-2 font-medium">Your Stats</div>
            <div className="grid grid-cols-2 gap-3">
              <div className="bg-gray-800/50 rounded-lg p-3 text-center">
                <div className="text-2xl font-bold text-white">{playerStats.wins}</div>
                <div className="text-xs text-gray-400">Wins</div>
              </div>
              <div className="bg-gray-800/50 rounded-lg p-3 text-center">
                <div className="text-2xl font-bold text-white">{playerStats.losses}</div>
                <div className="text-xs text-gray-400">Losses</div>
              </div>
              <div className="bg-gray-800/50 rounded-lg p-3 text-center">
                <div className="text-2xl font-bold text-white">{playerStats.draws}</div>
                <div className="text-xs text-gray-400">Draws</div>
              </div>
              <div className="bg-gray-800/50 rounded-lg p-3 text-center">
                <div className="text-2xl font-bold text-green-400">{playerStats.totalPoints}</div>
                <div className="text-xs text-gray-400">Points</div>
              </div>
            </div>
          </div>
        )}

        {/* Back button */}
        <div className="mt-6 flex justify-center">
          <Button variant="outline" onClick={() => router.push('/')}>
            Back to Game
          </Button>
        </div>

        {/* Footer */}
        {address && (
          <div className="mt-6 text-center text-xs text-gray-500 font-mono">
            {address.slice(0, 8)}...{address.slice(-6)}
          </div>
        )}
      </div>
    </div>
  );
}
