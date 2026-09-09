import 'package:json_annotation/json_annotation.dart';

part 'model_044.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model044 {
  const Model044({required this.id, required this.value});

  final int id;
  final String value;

  factory Model044.fromJson(Map<String, dynamic> json) =>
      _$Model044FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model044ToJson(this);
}
