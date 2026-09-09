import 'package:json_annotation/json_annotation.dart';

part 'model_429.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model429 {
  const Model429({required this.id, required this.value});

  final int id;
  final String value;

  factory Model429.fromJson(Map<String, dynamic> json) =>
      _$Model429FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model429ToJson(this);
}
