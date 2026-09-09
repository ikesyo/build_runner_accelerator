import 'package:json_annotation/json_annotation.dart';

part 'model_166.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model166 {
  const Model166({required this.id, required this.value});

  final int id;
  final String value;

  factory Model166.fromJson(Map<String, dynamic> json) =>
      _$Model166FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model166ToJson(this);
}
