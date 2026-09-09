import 'package:json_annotation/json_annotation.dart';

part 'model_071.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model071 {
  const Model071({required this.id, required this.value});

  final int id;
  final String value;

  factory Model071.fromJson(Map<String, dynamic> json) =>
      _$Model071FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model071ToJson(this);
}
