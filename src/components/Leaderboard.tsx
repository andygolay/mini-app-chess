'use client';

import React, { useEffect, useState, useCallback } from 'react';
import { CHESS_MODULE_ADDRESS } from '../../constants';
import { formatAddress } from '../utils/chess';
import type { PlayerStats, LeaderboardEntry } from '../types/chess';

interface LeaderboardProps {
  sdk: any;
  address: string | null;
}

export function Leaderboard({ sdk, address }: LeaderboardProps) {
  const [entries, setEntries] = useState<LeaderboardEntry[]>([]);
  const [playerStats, setPlayerStats] = useState<PlayerStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const fetchLeaderboard = useCallback(async () => {
    if (!sdk) return;

    try {
      // Get leaderboard
      const lbResult = await sdk.view({
        function: `${CHESS_MODULE_ADDRESS}::chess::get_leaderboard`,
        type_arguments: [],
        function_arguments: [],
      });

      const [addresses, points] = Array.isArray(lbResult)
        ? lbResult
        : [[], []];

      const leaderboardEntries: LeaderboardEntry[] = (addresses as string[]).map(
        (addr: string, idx: number) => ({
          address: addr,
          points: Number((points as string[])[idx] || 0),
          rank: idx + 1,
        })
      );

      setEntries(leaderboardEntries.slice(0, 10));

      // Get player's own stats if connected
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

  if (isLoading) {
    return (
      <div className="bg-gray-800/50 rounded-xl p-4 border border-gray-700/50">
        <h3 className="text-lg font-semibold text-white mb-3">Leaderboard</h3>
        <div className="text-gray-400 text-sm">Loading...</div>
      </div>
    );
  }

  return (
    <div className="bg-gray-800/50 rounded-xl p-4 border border-gray-700/50">
      <h3 className="text-lg font-semibold text-white mb-3">Leaderboard</h3>

      {/* Player's own stats */}
      {playerStats && playerStats.gamesPlayed > 0 && (
        <div className="mb-4 p-3 bg-green-900/30 rounded-lg border border-green-700/50">
          <div className="text-sm text-green-400 mb-1">Your Stats</div>
          <div className="grid grid-cols-2 gap-2 text-xs">
            <div>
              <span className="text-gray-400">Wins:</span>{' '}
              <span className="text-white font-medium">{playerStats.wins}</span>
            </div>
            <div>
              <span className="text-gray-400">Losses:</span>{' '}
              <span className="text-white font-medium">{playerStats.losses}</span>
            </div>
            <div>
              <span className="text-gray-400">Draws:</span>{' '}
              <span className="text-white font-medium">{playerStats.draws}</span>
            </div>
            <div>
              <span className="text-gray-400">Points:</span>{' '}
              <span className="text-green-400 font-medium">{playerStats.totalPoints}</span>
            </div>
          </div>
        </div>
      )}

      {/* Top players */}
      {entries.length > 0 ? (
        <div className="space-y-2">
          {entries.map((entry) => {
            const isCurrentPlayer = address && entry.address.toLowerCase() === address.toLowerCase();
            return (
              <div
                key={entry.address}
                className={`flex items-center justify-between p-2 rounded-lg ${
                  isCurrentPlayer
                    ? 'bg-blue-900/30 border border-blue-700/50'
                    : 'bg-gray-700/30'
                }`}
              >
                <div className="flex items-center gap-3">
                  <span
                    className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold ${
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
                  <span className="text-gray-200 font-mono text-sm">
                    {formatAddress(entry.address)}
                  </span>
                </div>
                <span className="text-green-400 font-semibold">
                  {entry.points.toLocaleString()}
                </span>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="text-gray-400 text-sm text-center py-4">
          No games played yet. Be the first!
        </div>
      )}
    </div>
  );
}

export default Leaderboard;
