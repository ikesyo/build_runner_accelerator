import 'package:json_annotation/json_annotation.dart';

part 'model_147.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model147 {
  const Model147({required this.id, required this.value});

  final int id;
  final String value;

  factory Model147.fromJson(Map<String, dynamic> json) =>
      _$Model147FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model147ToJson(this);
}
