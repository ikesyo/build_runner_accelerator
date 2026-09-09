import 'package:json_annotation/json_annotation.dart';

part 'model_239.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model239 {
  const Model239({required this.id, required this.value});

  final int id;
  final String value;

  factory Model239.fromJson(Map<String, dynamic> json) =>
      _$Model239FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model239ToJson(this);
}
