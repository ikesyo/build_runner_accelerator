import 'package:json_annotation/json_annotation.dart';

part 'model_160.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model160 {
  const Model160({required this.id, required this.value});

  final int id;
  final String value;

  factory Model160.fromJson(Map<String, dynamic> json) =>
      _$Model160FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model160ToJson(this);
}
