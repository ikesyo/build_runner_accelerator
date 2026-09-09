import 'package:json_annotation/json_annotation.dart';

part 'model_407.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model407 {
  const Model407({required this.id, required this.value});

  final int id;
  final String value;

  factory Model407.fromJson(Map<String, dynamic> json) =>
      _$Model407FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model407ToJson(this);
}
