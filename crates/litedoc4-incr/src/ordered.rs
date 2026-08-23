//! A `name -> value` map that remembers the order its keys arrived in.
//!
//! Two files this crate writes are JSON objects whose **key order is part of
//! the bytes**: the ledger's `extractKey` / `renderKey`
//! ([`crate::ledger::KeySet`]) and the merged `index.json`
//! ([`crate::merge::JsonObject`]). Both were built key by key by a prototype in
//! JavaScript, where an object keeps insertion order, and both are compared
//! against that prototype's bytes. A `BTreeMap` would re-sort them and
//! `serde_json`'s own map would only keep the order *with the `preserve_order`
//! feature on* — plan §7 says to reproduce the order explicitly rather than to
//! inherit it from a dependency's build configuration.
//!
//! So there is one type here, [`Ordered`], and the two files name their value
//! types. Before this module the two were written out separately, hand-written
//! `Serialize` / `Deserialize` included, and **both spellings decide bytes** —
//! the shape where one gets fixed and the other does not.
//!
//! [`Deserialize`] is *not* implemented here. It is implemented at each alias,
//! over [`Ordered::deserialize_in_order`], because the one thing that genuinely
//! differs between the two is what a refusal says it wanted: a ledger key set
//! is "a map of strings to strings", an index is "a JSON object".

use serde::de::{MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A `name -> value` map in insertion order.
///
/// An association list, not a hash map: the two files it backs hold a handful
/// of keys each, and the order is the point. Callers that need a lookup inside
/// a loop over a package's modules build their own index — see the `previous`
/// map in [`crate::detect`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ordered<V>(Vec<(String, V)>);

impl<V> Default for Ordered<V> {
    fn default() -> Self {
        Self(Vec::new())
    }
}

impl<V> Ordered<V> {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a key, or replaces the value of one already present **in place**.
    ///
    /// The first position is kept and the last value is taken — which is what
    /// assigning to a JavaScript object property does, whether the assignment
    /// comes from a spread followed by a property write (which is what makes
    /// the merged index keep the base index's key order) or from reading a
    /// duplicated key out of a hand-edited file, which has to round-trip.
    pub fn insert(&mut self, key: impl Into<String>, value: impl Into<V>) {
        let key = key.into();
        let value = value.into();
        match self.0.iter_mut().find(|(name, _)| *name == key) {
            Some(slot) => slot.1 = value,
            None => self.0.push((key, value)),
        }
    }

    #[must_use]
    pub fn get(&self, key: &str) -> Option<&V> {
        self.0
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.0.iter().map(|(name, _)| name.as_str())
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &V)> {
        self.0.iter().map(|(name, value)| (name.as_str(), value))
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Reads a JSON object into insertion order, applying [`Ordered::insert`]'s
    /// rule to a repeated key.
    ///
    /// `expecting` is what the refusal names when the value is not a map at
    /// all, and it is why the [`Deserialize`] impls are at the aliases rather
    /// than here: the message names the file, and this type does not know which
    /// file it is.
    pub(crate) fn deserialize_in_order<'de, D>(
        deserializer: D,
        expecting: &'static str,
    ) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
        V: Deserialize<'de>,
    {
        struct OrderedVisitor<V> {
            expecting: &'static str,
            value: std::marker::PhantomData<V>,
        }

        impl<'de, V: Deserialize<'de>> Visitor<'de> for OrderedVisitor<V> {
            type Value = Ordered<V>;

            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str(self.expecting)
            }

            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Ordered<V>, M::Error> {
                let mut out = Ordered::new();
                while let Some((key, value)) = map.next_entry::<String, V>()? {
                    out.insert(key, value);
                }
                Ok(out)
            }
        }

        deserializer.deserialize_map(OrderedVisitor {
            expecting,
            value: std::marker::PhantomData,
        })
    }
}

impl<V: Serialize> Serialize for Ordered<V> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_map(self.iter())
    }
}
