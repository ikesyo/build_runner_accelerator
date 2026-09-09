import 'package:json_annotation/json_annotation.dart';

part 'model_378.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model378 {
  const Model378({required this.id, required this.value});

  final int id;
  final String value;

  factory Model378.fromJson(Map<String, dynamic> json) =>
      _$Model378FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model378ToJson(this);
}
