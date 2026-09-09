import 'package:json_annotation/json_annotation.dart';

part 'model_421.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model421 {
  const Model421({required this.id, required this.value});

  final int id;
  final String value;

  factory Model421.fromJson(Map<String, dynamic> json) =>
      _$Model421FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model421ToJson(this);
}
